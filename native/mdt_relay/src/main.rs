//! The first process in the bubble MDT runs microsandbox in.
//!
//! The bubble (bwrap) has its own network with only loopback, so msb has no
//! way out but what this program joins to MDT's sockets:
//!
//! ```text
//! 127.0.0.1:3128  (TCP)       ->  SOCKETS/proxy.sock   msb's --proxy
//! 127.0.0.1:5353  (UDP, TCP)  ->  SOCKETS/dns.sock     msb's --dns-nameserver
//! ```
//!
//! It does five things, in this order:
//!
//! 1. adds a default route into loopback, then gives up every capability for
//!    good. msb gives the VM an IPv4 address only when the kernel can pick a
//!    route to a public address; this one leads nowhere;
//! 2. joins the two loopback ports to the two sockets;
//! 3. runs the `msb create` or `msb start` it was given, and writes how that
//!    went to `SOCKETS/start.out` (exit status on the first line);
//! 4. answers `SOCKETS/control.sock`: `status`, and `stop`, which runs
//!    `msb stop` and then exits. SIGTERM stops the same way;
//! 5. exits when the VM's process is gone.
//!
//! It runs as process 1 of the bubble's PID namespace (`bwrap --as-pid-1`),
//! so when it exits, however that happens, the kernel ends every other
//! process in the bubble: the VM runs exactly as long as this does. Being
//! process 1, it also collects the processes that end there.
//!
//! One relay per VM: it holds `SOCKETS/relay.lock`, and a second one for the
//! same sockets refuses to start rather than take over the first one's
//! control socket.
//!
//! ```text
//! mdt-relay --sockets DIR --name VM [--no-route] -- MSB ARG...
//! mdt-relay --check
//! ```

use std::env;
use std::ffi::CString;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{Ipv4Addr, Shutdown, TcpListener, TcpStream, UdpSocket};
use std::os::raw::{c_char, c_int, c_long, c_ulong};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{exit, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(not(target_pointer_width = "64"))]
compile_error!("mdt-relay is written for 64-bit Linux");

const PROXY_PORT: u16 = 3128;
const DNS_PORT: u16 = 5353;
const BUFFER: usize = 256 * 1024;
const DNS_IN_FLIGHT: usize = 256;
const DNS_ANSWER_WITHIN: Duration = Duration::from_secs(6);
const STOP_WITHIN: Duration = Duration::from_secs(90);

static STOP: AtomicBool = AtomicBool::new(false);

extern "C" fn on_terminate(_signal: c_int) {
    STOP.store(true, Ordering::SeqCst);
}

// ---- The few system calls std has no name for ------------------------------

extern "C" {
    fn socket(domain: c_int, kind: c_int, protocol: c_int) -> c_int;
    fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn prctl(option: c_int, ...) -> c_int;
    fn syscall(number: c_long, ...) -> c_long;
    fn signal(signum: c_int, handler: usize) -> usize;
    fn getuid() -> u32;
    fn waitpid(pid: c_int, status: *mut c_int, options: c_int) -> c_int;
}

const WNOHANG: c_int = 1;

const AF_INET: c_int = 2;
const SOCK_DGRAM: c_int = 2;
const SIOCADDRT: c_ulong = 0x890B;
const RTF_UP: u16 = 0x0001;
const SIGTERM: c_int = 15;
const SIGPIPE: c_int = 13;
const SIG_IGN: usize = 1;
const PR_CAPBSET_DROP: c_int = 24;
const PR_CAP_AMBIENT: c_int = 47;
const PR_CAP_AMBIENT_CLEAR_ALL: c_ulong = 4;
const LINUX_CAPABILITY_VERSION_3: u32 = 0x2008_0522;
#[cfg(target_arch = "x86_64")]
const SYS_CAPSET: c_long = 126;
#[cfg(target_arch = "aarch64")]
const SYS_CAPSET: c_long = 91;

// `struct sockaddr_in`, the size of `struct sockaddr`.
#[repr(C)]
struct SockAddr {
    family: u16,
    port: u16,
    address: u32,
    zero: [u8; 8],
}

// `struct rtentry` from <net/route.h>, as it is on 64-bit Linux.
#[repr(C)]
struct RtEntry {
    rt_pad1: c_ulong,
    rt_dst: SockAddr,
    rt_gateway: SockAddr,
    rt_genmask: SockAddr,
    rt_flags: u16,
    rt_pad2: i16,
    rt_pad3: c_ulong,
    rt_tos: u8,
    rt_class: u8,
    rt_pad4: [i16; 3],
    rt_metric: i16,
    rt_dev: *const c_char,
    rt_mtu: c_ulong,
    rt_window: c_ulong,
    rt_irtt: u16,
}

#[repr(C)]
struct CapHeader {
    version: u32,
    pid: c_int,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CapData {
    effective: u32,
    permitted: u32,
    inheritable: u32,
}

/// `ip route add default dev lo`: every address has a route, and it leads
/// back here, where nothing answers.
fn add_default_route() -> io::Result<()> {
    let any = || SockAddr { family: AF_INET as u16, port: 0, address: 0, zero: [0; 8] };
    let device = CString::new("lo").expect("no NUL");

    let route = RtEntry {
        rt_pad1: 0,
        rt_dst: any(),
        rt_gateway: any(),
        rt_genmask: any(),
        rt_flags: RTF_UP,
        rt_pad2: 0,
        rt_pad3: 0,
        rt_tos: 0,
        rt_class: 0,
        rt_pad4: [0; 3],
        rt_metric: 0,
        rt_dev: device.as_ptr(),
        rt_mtu: 0,
        rt_window: 0,
        rt_irtt: 0,
    };

    unsafe {
        let fd = socket(AF_INET, SOCK_DGRAM, 0);
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let result = ioctl(fd, SIOCADDRT, &route as *const RtEntry);
        let error = io::Error::last_os_error();
        close(fd);
        if result < 0 {
            return Err(error);
        }
    }
    Ok(())
}

/// Gives up every capability, and the means to get one back: the bounding
/// set is emptied first, so nothing this process runs (msb is root in the
/// bubble) can hold one either.
fn drop_capabilities() -> Result<(), String> {
    unsafe {
        for capability in 0..64 as c_ulong {
            // Fails for numbers the kernel doesn't know; checked below.
            prctl(PR_CAPBSET_DROP, capability, 0 as c_ulong, 0 as c_ulong, 0 as c_ulong);
        }
        prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0 as c_ulong, 0 as c_ulong, 0 as c_ulong);

        let header = CapHeader { version: LINUX_CAPABILITY_VERSION_3, pid: 0 };
        let none = [CapData { effective: 0, permitted: 0, inheritable: 0 }; 2];
        if syscall(SYS_CAPSET, &header as *const CapHeader, none.as_ptr()) != 0 {
            return Err(format!("capset: {}", io::Error::last_os_error()));
        }
    }

    let status = fs::read_to_string("/proc/self/status").map_err(|e| e.to_string())?;
    let held = |name: &str| -> bool {
        status
            .lines()
            .find(|line| line.starts_with(name))
            .and_then(|line| line.split_whitespace().nth(1))
            .map(|hex| hex.trim_start_matches('0') != "")
            .unwrap_or(true)
    };

    // The bounding set only matters to root, which is what this is in the
    // bubble. Outside one (the tests) an ordinary user keeps it and has
    // nothing to gain from it.
    let root = unsafe { getuid() } == 0;
    if held("CapEff:") || held("CapPrm:") || (root && held("CapBnd:")) {
        return Err("some capability is still held".into());
    }
    Ok(())
}

// ---- Moving bytes ----------------------------------------------------------

fn pump(mut from: impl Read, mut to: impl Write) {
    let mut buffer = vec![0u8; BUFFER];
    loop {
        match from.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(count) => {
                if to.write_all(&buffer[..count]).is_err() {
                    break;
                }
            }
        }
    }
}

/// Joins a connection msb made to one of MDT's sockets, both ways, passing
/// each side's end of stream on to the other.
fn join(client: TcpStream, path: &Path) {
    let _ = client.set_nodelay(true);
    let Ok(mdt) = UnixStream::connect(path) else {
        // MDT isn't listening: msb sees the connection close, the VM a refusal.
        return;
    };
    let (Ok(client_out), Ok(mdt_out)) = (client.try_clone(), mdt.try_clone()) else {
        return;
    };

    let up = thread::spawn(move || {
        pump(&client, &mdt_out);
        let _ = mdt_out.shutdown(Shutdown::Write);
    });
    pump(&mdt, &client_out);
    let _ = client_out.shutdown(Shutdown::Write);
    let _ = up.join();
}

fn serve_tcp(listener: TcpListener, path: PathBuf) {
    for client in listener.incoming().flatten() {
        let path = path.clone();
        thread::spawn(move || join(client, &path));
    }
}

/// One DNS question to MDT and its answer, framed as DNS over TCP is: two
/// bytes of length, then the message.
fn ask(path: &Path, question: &[u8]) -> io::Result<Vec<u8>> {
    let mut mdt = UnixStream::connect(path)?;
    mdt.set_read_timeout(Some(DNS_ANSWER_WITHIN))?;
    mdt.set_write_timeout(Some(DNS_ANSWER_WITHIN))?;
    mdt.write_all(&(question.len() as u16).to_be_bytes())?;
    mdt.write_all(question)?;
    let mut length = [0u8; 2];
    mdt.read_exact(&mut length)?;
    let mut answer = vec![0u8; u16::from_be_bytes(length) as usize];
    mdt.read_exact(&mut answer)?;
    Ok(answer)
}

fn serve_dns_udp(socket: UdpSocket, path: PathBuf) {
    let in_flight = Arc::new(AtomicUsize::new(0));
    let mut buffer = [0u8; 4096];

    loop {
        let Ok((count, sender)) = socket.recv_from(&mut buffer) else { continue };
        // A flood of questions is dropped, as a resolver would.
        if in_flight.load(Ordering::SeqCst) >= DNS_IN_FLIGHT {
            continue;
        }
        let Ok(reply_on) = socket.try_clone() else { continue };
        let question = buffer[..count].to_vec();
        let path = path.clone();
        let in_flight = in_flight.clone();
        in_flight.fetch_add(1, Ordering::SeqCst);

        thread::spawn(move || {
            if let Ok(answer) = ask(&path, &question) {
                let _ = reply_on.send_to(&answer, sender);
            }
            in_flight.fetch_sub(1, Ordering::SeqCst);
        });
    }
}

// ---- The VM ----------------------------------------------------------------

#[derive(Clone, Copy, PartialEq)]
enum Phase {
    Starting,
    Running,
    Stopped,
}

struct State {
    phase: Phase,
    stop_asked: bool,
    stop_output: String,
}

/// Whether the VM's process (`msb machine ... --name NAME ...`) is alive.
/// The bubble has its own /proc, so only its own processes are looked at.
fn machine_running(name: &str) -> bool {
    let Ok(entries) = fs::read_dir("/proc") else { return false };

    for entry in entries.flatten() {
        let file = entry.file_name();
        let Some(pid) = file.to_str() else { continue };
        if !pid.bytes().all(|byte| byte.is_ascii_digit()) {
            continue;
        }
        let Ok(raw) = fs::read(format!("/proc/{pid}/cmdline")) else { continue };
        let words: Vec<&[u8]> = raw.split(|byte| *byte == 0).collect();

        if words.len() > 3
            && words[1] == b"machine"
            && words.windows(2).any(|pair| pair[0] == b"--name" && pair[1] == name.as_bytes())
        {
            return true;
        }
    }
    false
}

/// Collects every process that has ended. As process 1 this inherits the
/// bubble's orphans (the VM's process is one, once `msb create` returns).
/// Called only between commands, never while `run` waits for one.
fn reap() {
    let mut status: c_int = 0;
    while unsafe { waitpid(-1, &mut status, WNOHANG) } > 0 {}
}

fn run(program: &str, arguments: &[String]) -> (i32, String) {
    match Command::new(program).args(arguments).stdin(Stdio::null()).output() {
        Ok(done) => {
            let mut text = String::from_utf8_lossy(&done.stdout).into_owned();
            text.push_str(&String::from_utf8_lossy(&done.stderr));
            (done.status.code().unwrap_or(-1), text)
        }
        Err(error) => (-1, format!("could not run {program}: {error}\n")),
    }
}

/// Written aside and renamed, so MDT never reads half of it.
fn write_whole(path: &Path, text: &str) {
    let partial = path.with_extension("part");
    if fs::write(&partial, text).is_ok() {
        let _ = fs::rename(&partial, path);
    }
}

fn serve_control(listener: UnixListener, state: Arc<Mutex<State>>) {
    for connection in listener.incoming().flatten() {
        let state = state.clone();
        thread::spawn(move || {
            let mut line = String::new();
            let mut reader = BufReader::new(&connection);
            if reader.by_ref().take(64).read_line(&mut line).is_err() {
                return;
            }
            let mut out = &connection;

            match line.trim() {
                "status" => {
                    let phase = state.lock().unwrap().phase;
                    let word = match phase {
                        Phase::Starting => "starting",
                        Phase::Running => "running",
                        Phase::Stopped => "stopped",
                    };
                    let _ = writeln!(out, "{word}");
                }
                "stop" => {
                    state.lock().unwrap().stop_asked = true;
                    let asked = Instant::now();
                    // The main thread stops the VM; this one reports it.
                    loop {
                        {
                            let state = state.lock().unwrap();
                            if state.phase == Phase::Stopped {
                                let _ = write!(out, "stopped\n{}", state.stop_output);
                                break;
                            }
                        }
                        if asked.elapsed() > STOP_WITHIN + Duration::from_secs(10) {
                            let _ = writeln!(out, "still stopping");
                            break;
                        }
                        thread::sleep(Duration::from_millis(50));
                    }
                }
                _ => {
                    let _ = writeln!(out, "unknown");
                }
            }
        });
    }
}

fn fail(message: &str) -> ! {
    eprintln!("mdt-relay: {message}");
    exit(2)
}

fn main() {
    let mut sockets: Option<PathBuf> = None;
    let mut name: Option<String> = None;
    let mut route = true;
    let mut check = false;
    let mut command: Vec<String> = Vec::new();
    let mut arguments = env::args().skip(1);

    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--sockets" => sockets = arguments.next().map(PathBuf::from),
            "--name" => name = arguments.next(),
            "--no-route" => route = false,
            "--check" => check = true,
            "--" => {
                command = arguments.by_ref().collect();
            }
            other => fail(&format!("unknown argument {other}")),
        }
    }

    // Whether a bubble made here lets the relay do its first two steps: MDT
    // asks before it offers to start a VM, so a system that refuses (an
    // AppArmor profile, say) is told apart from one that works.
    if check {
        if let Err(error) = add_default_route() {
            fail(&format!("could not add the default route into loopback: {error}"));
        }
        if let Err(error) = drop_capabilities() {
            fail(&format!("could not give up capabilities: {error}"));
        }
        println!("ok");
        return;
    }

    let (Some(sockets), Some(name)) = (sockets, name) else {
        fail("usage: mdt-relay --sockets DIR --name VM [--no-route] -- MSB ARG...")
    };
    if command.is_empty() {
        fail("nothing to run after --");
    }
    let msb = command[0].clone();

    // One relay per VM. The lock is held until this process ends.
    let lock = fs::File::create(sockets.join("relay.lock"))
        .unwrap_or_else(|error| fail(&format!("{}: {error}", sockets.display())));
    if lock.try_lock().is_err() {
        eprintln!("mdt-relay: a relay is already running for this VM");
        exit(3);
    }
    std::mem::forget(lock);

    // 1. The route, then no capability left.
    if route {
        if let Err(error) = add_default_route() {
            fail(&format!("could not add the default route into loopback: {error}"));
        }
    }
    if let Err(error) = drop_capabilities() {
        fail(&format!("could not give up capabilities: {error}"));
    }

    unsafe {
        signal(SIGTERM, on_terminate as *const () as usize);
        // A peer closing mid-write is an error to handle, not a reason to die.
        signal(SIGPIPE, SIG_IGN);
    }

    // 2. msb's two ways out.
    let loopback = Ipv4Addr::LOCALHOST;
    let proxy = TcpListener::bind((loopback, PROXY_PORT))
        .unwrap_or_else(|error| fail(&format!("port {PROXY_PORT}: {error}")));
    let dns_tcp = TcpListener::bind((loopback, DNS_PORT))
        .unwrap_or_else(|error| fail(&format!("port {DNS_PORT}: {error}")));
    let dns_udp = UdpSocket::bind((loopback, DNS_PORT))
        .unwrap_or_else(|error| fail(&format!("port {DNS_PORT}/udp: {error}")));

    let proxy_socket = sockets.join("proxy.sock");
    let dns_socket = sockets.join("dns.sock");
    thread::spawn(move || serve_tcp(proxy, proxy_socket));
    {
        let dns_socket = dns_socket.clone();
        thread::spawn(move || serve_tcp(dns_tcp, dns_socket));
    }
    thread::spawn(move || serve_dns_udp(dns_udp, dns_socket));

    // 4. (before 3, so MDT can ask how the start is going)
    let state = Arc::new(Mutex::new(State {
        phase: Phase::Starting,
        stop_asked: false,
        stop_output: String::new(),
    }));
    let control_path = sockets.join("control.sock");
    let start_out = sockets.join("start.out");
    let _ = fs::remove_file(&control_path);
    let _ = fs::remove_file(&start_out);
    let control = UnixListener::bind(&control_path)
        .unwrap_or_else(|error| fail(&format!("{}: {error}", control_path.display())));
    {
        let state = state.clone();
        thread::spawn(move || serve_control(control, state));
    }

    // 3. The VM.
    let (status, output) = run(&msb, &command[1..]);
    write_whole(&start_out, &format!("{status}\n{output}"));
    if status != 0 {
        let _ = fs::remove_file(&control_path);
        exit(1);
    }
    state.lock().unwrap().phase = Phase::Running;

    // 5. Until the VM is gone, or a stop is asked for.
    let mut missing = 0;
    loop {
        thread::sleep(Duration::from_millis(250));
        reap();

        if STOP.load(Ordering::SeqCst) || state.lock().unwrap().stop_asked {
            let (_status, mut output) = run(&msb, &["stop".to_string(), name.clone()]);
            let asked = Instant::now();
            while machine_running(&name) && asked.elapsed() < STOP_WITHIN {
                thread::sleep(Duration::from_millis(100));
            }
            if machine_running(&name) {
                output.push_str("The VM did not stop in time; it ends with the bubble.\n");
            }
            {
                let mut state = state.lock().unwrap();
                state.stop_output = output;
                state.phase = Phase::Stopped;
            }
            // Time for the answer to `stop` to go out.
            thread::sleep(Duration::from_millis(300));
            let _ = fs::remove_file(&control_path);
            exit(0);
        }

        if machine_running(&name) {
            missing = 0;
        } else {
            missing += 1;
            if missing >= 2 {
                let _ = fs::remove_file(&control_path);
                exit(0);
            }
        }
    }
}
