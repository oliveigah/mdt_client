# Local accounts and encryption at rest

Status: implemented. Supersedes the mocked `Accounts.mock_user/1` login.

## Goal

Everything MDT persists must be encrypted on disk, and data belonging to one
user must be unreadable by another — including when both choose the same
password. Today that means the HTTP client's request history; the same vault
serves any store added later.

## Crypto

Every primitive comes from OTP's `:crypto`. Nothing is hand-rolled, and there
are no cryptographic dependencies.

| Purpose | Call |
| --- | --- |
| password → key | `:crypto.pbkdf2_hmac(:sha512, password, salt, 600_000, 32)` |
| encrypt / decrypt | `:crypto.crypto_one_time_aead(:aes_256_gcm, …)` |
| salt, nonce, tokens | `:crypto.strong_rand_bytes/1` |
| directory naming | `:crypto.hash(:sha256, username)` |

The password *is* the key — there is no wrapped data key. That keeps the design
to one derivation and one cipher, at the cost of a full re-encrypt whenever the
password changes. See "Rejected: the envelope" below.

600,000 PBKDF2 iterations costs roughly 150 ms per unlock. OWASP's published
figure for PBKDF2-HMAC-SHA512 is 210,000; the extra margin is imperceptible at
app launch.

Every write gets a fresh 12-byte nonce. Reusing a nonce under the same AES-GCM
key leaks the XOR of both plaintexts and exposes the authentication subkey,
which permits forgery — and the history file is rewritten every 30 seconds, so
this is a live concern rather than a theoretical one.

### Blob format

    <<version::8, nonce::96, tag::128, ciphertext::binary>>

Plaintext is `:erlang.term_to_binary/1`. The GCM tag is verified before
anything is deserialised, so a tampered file is rejected rather than decoded —
and because only a holder of the key could produce a blob that authenticates,
the term is always one we wrote ourselves.

Decoding deliberately does **not** pass `:safe`. That flag refuses to create
atoms the VM has not seen, and a freshly started VM has not yet loaded the
modules whose struct names are in the history, so `:safe` rejects our own data
on precisely the restart where restoring matters.

## Durability

The history is flushed about 250ms after any change — a new request, a tag, a
description — rather than only on a timer and at shutdown. A desktop app can
be force quit or killed, in which case `terminate/2` never runs; anything
relying on it alone is lost. The 30 second sync remains as a backstop, and
`clear` and `delete` still write synchronously.

A history file that will not decrypt is renamed aside with a timestamp rather
than overwritten, so a bad start can never destroy a recoverable copy.

## Identity

A user is a `{username, password}` pair. Usernames are trimmed and downcased
before use; the directory name is `sha256(normalised_username)` in hex, which
sidesteps filesystem-unsafe characters and keeps a directory listing from
enumerating who uses the machine.

Each user gets a random salt, so two users sharing a password still derive
different keys and cannot read each other's files.

## Layout

    ~/.mdt_client/
      preferences.json                  plaintext — theme, last_username
      identities/<sha256(username)>/
        vault.json                      version, username, kdf params, salt, verifier
        http_history.bin                AES-256-GCM

Nothing in `vault.json` is secret. The verifier is a known constant sealed
under the derived key at creation; opening it proves the password is right.
That also separates the two failure modes — if the verifier opens but the
history does not, the history is damaged, not the password wrong.

`preferences.json` stays in the clear so the app can render the theme before
anyone logs in. It deliberately holds one piece of user data, `last_username`,
to prefill the login form.

## Sign-in

    username + password
       │
       ├─ no vault.json?  → create: random salt, derive key, write verifier
       │
       └─ vault.json?     → derive key from the stored salt, open the verifier
                              opens  → unlock
                              :error → "Incorrect password"

An unknown username creates a profile rather than erroring, so the login form
says so before submit — otherwise a typo silently produces an empty history and
looks like data loss.

## Runtime

`Vault.Store` is a `DynamicSupervisor` plus a `Registry`. Unlocking starts one
process per store for that user, holding the derived key and an ETS table;
locking terminates it, so key and plaintext leave memory together. The key is
never written to disk and never reaches the browser — the session cookie holds
only an opaque token, and Phoenix session cookies are signed but readable.

Every `Resources` and `Core` function takes the username. A LiveView left over
from an earlier session therefore addresses a dead process and fails, rather
than silently reading whoever logged in next.

## Deliberately not built

**No recovery.** Forget the password and that user's history is unrecoverable.

**No password change yet.** The design permits it as decrypt-all /
re-encrypt-all.

**Rejected: the envelope.** The common alternative is a random data key (DEK)
that encrypts the data, itself encrypted by a password-derived key (KEK), as
LUKS keyslots and `age` recipients do. It adds no security — cracking the
password still yields everything — but it makes password changes cheap and
allows several ways in (SSH agent, a server-held blob, a recovery code) to
share one copy of the data. All of those are deprioritised, and retrofitting it
costs exactly one re-encrypt pass, the same operation as a password change.

**No cloud server.** If one is added, the server should hold only a *wrapped*
key, never a raw one: derive `auth = HKDF(key, "auth")` for login and keep the
encryption key on the device. A server that holds both keys and ciphertext can
read every user's data.

**No SSH-key or OS-keychain unlock.** The key source is one function; either can
be added there without touching storage.

## Reaching the app over HTTP

The vault is served by a Phoenix endpoint on loopback, so "can another program
just call the history route" is a fair question. Four things answer it.

**There is no history route.** History is rendered inside a LiveView over a
WebSocket; nothing exposes it as an HTTP endpoint to call.

**Every tool route requires a session.** `MDTClientWeb.UserAuth` halts and
redirects to `/` unless the cookie carries a live token *and* that identity's
vault is still open.

**The endpoint binds to 127.0.0.1**, and that is now the default rather than
something a missing environment variable can switch off. `PHX_BIND_ALL=true`
opts into a public interface for a real deployment; nothing else does.

**Loopback binding alone does not stop DNS rebinding.** A page the user visits
can point its own domain at 127.0.0.1, after which the browser treats this app
as same origin. `check_origin: :conn` does *not* catch this — it only checks
that `Origin` agrees with `Host`, and a rebinding attacker controls both. So
the accepted origins are pinned to the loopback names in `config/runtime.exs`,
and `MDTClientWeb.Plugs.LoopbackHost` rejects any request whose `Host` is not
a loopback name, which also keeps sign in from being driven that way. The
session cookie is `SameSite=Strict` and `HttpOnly` on top of that.

## Threat model

Protects against someone who obtains the files — a synced folder, a backup, a
stolen disk: they get ciphertext, file sizes and timestamps. Tampering is
detected. Cross-user access is prevented arithmetically, not by a UI check.

Does not protect against anything running as you while a vault is unlocked: the
key is in memory, and a process with your privileges can read it, read the
WebView's cookie jar, or read `~/.mdt_client` and attack the vault offline —
which is faster than going through the HTTP port anyway. That is why there is
no login rate limit: it would slow the one attacker who cannot already take the
quicker path.

Nor does it protect against a weak password, which is the only thing standing
between someone holding the files and the plaintext.
