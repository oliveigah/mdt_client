# Export and import

Status: implemented. Today an export holds the HTTP client's request history;
anything that keeps per-identity data can join by implementing one behaviour.

## Goal

Move everything an identity keeps between MDT installations — through a
synced folder, a USB stick, onto a new laptop — in one file. The installation
receiving it may already hold data of its own, so importing merges by default:
what the file holds is added to what is there, and nothing there is lost.
Replacing is the other option.

An export belongs to the identity that made it: it is sealed with that
identity's password, and its file name carries the username.

## Shape

The subsystem owns no data. It knows which systems do, asks each of them for
its data when exporting, and hands each its data back when importing.

    MDTClient.Transfer                orchestrates: export, read, import
    MDTClient.Transfer.Participant    the behaviour a system implements
    MDTClient.Transfer.Archive        the file format and its encryption
    MDTClient.Transfer.Plan           an opened file, ready to import
    MDTClient.HttpClient.Transfer     the request history's participant
    MDTClient.Vault.Keyring           seals and opens with the identity's key

A participant answers eight callbacks:

| Callback | Purpose |
| --- | --- |
| `key/0` | names its section in the file; never changes once shipped |
| `label/0` | what the section is, for people |
| `version/0` | the shape of what `export/1` produces |
| `export/1` | everything it keeps for an identity |
| `prepare/2` | checks and upgrades a section, touching nothing |
| `describe/1` | a short summary for the import preview, e.g. "42 requests" |
| `merge/2` | combines prepared data with what it keeps, losing nothing |
| `replace/2` | swaps what it keeps for prepared data |

`MDTClient.Transfer.participants/0` lists them, and that order is the order
they are imported in.

### Adding a participant

1. Write a module implementing `MDTClient.Transfer.Participant`. Keep it next
   to the system it serves, as `MDTClient.HttpClient.Transfer` is.
2. Export plain data you control: leave out identifiers that only mean
   something locally, and anything derived that `prepare/2` can rebuild.
3. Decide how your data merges — see below — and give the system a way to
   rewrite all of its data in one step, which both `merge/2` and `replace/2`
   can use.
4. Add the module to `@participants` in `MDTClient.Transfer`.

When the exported shape changes later, bump `version/0` and add a `prepare/2`
clause for the old version that upgrades it. Old files keep importing.

## Merging

Only a participant knows what counts as the same item on both sides and which
side wins where they differ, so merging is its own call. The behaviour sets
two rules for it:

* **Nothing local is lost.** Whatever the identity already has survives the
  merge, even if the file disagrees with it.
* **Merging is idempotent.** Importing the same file twice, or a file this
  identity exported itself, leaves things as they were after the first time.
  Merging must recognise what it already has rather than add it again.

The HTTP history is a list of requests, so its merge is a union:

* **Same request** means the same start and completion instants, method and
  URL. Timestamps carry microseconds, so two different requests all but never
  match, while a request copied between installations always does.
* **New requests** are added. Repeats within the file come in once.
* **Requests both sides hold** keep the version here, which gains any tags it
  lacks, and the file's description if it has none of its own.
* **Order** is by completion time, so imported requests land among the local
  ones where they happened, rather than all on top.

Every entry, local ones included, is numbered afresh, as with replacing.

## Import

Importing takes two steps, and the page puts the user between them.

**Read.** `Transfer.read/3` decrypts the file — "The key" below covers how —
and runs every participant's `prepare/2` over its section. Nothing is written.
If any section cannot be read — damaged, or from a newer version than this
build understands — the whole file is refused, so nothing is ever half
imported because of the file. Sections no participant recognises (written by
a newer build that has more participants) are listed as skipped rather than
refused, since there is nothing here that could read them. The result is a
`Plan`, which the page shows: who exported the file and when, and what each
section holds. The user then chooses to merge (the default) or replace.

**Import.** `Transfer.import/3` hands each section to its participant's
`merge/2` or `replace/2`. Should one fail partway, the sections already
written are put back as they were — by exporting each one just before writing
it and, on failure, handing that copy to `replace/2`. That works whichever
mode the import ran in. The last section needs no copy, so with a single
participant this costs nothing. A participant that raises or exits counts as
one that failed, so rollback still runs.

A participant the file holds no section for keeps its data untouched in both
modes.

The request history is rewritten in one step inside the process that owns it
(`Resources.rewrite/2`), and renumbered: entries take fresh identifiers from
the counter, so an identifier some open tab still holds finds nothing rather
than a different request. The new entries are written before the old ones are
removed, and only the entries the rewrite was given are removed, so a request
that completes while an import runs is kept.

## File format

    <<"MDTEXPORT", version::8, header_size::32, header::binary, payload::binary>>

The header is JSON. Its `kdf` is copied from the identity's `vault.json`:

    {"kdf": {"algorithm": "pbkdf2-hmac-sha512", "iterations": 600000,
             "length": 32, "salt": "<base64>"},
     "verifier": "<base64 Vault.seal(key, constant)>"}

The payload is `Vault.seal(key, term_to_binary(contents, compressed: 6))`,
where `contents` is:

    %{created_at: DateTime, username: String, app_version: String,
      sections: %{key => %{version: pos_integer, data: term}}}

Everything is built from `MDTClient.Vault`, so the crypto is exactly the
vault's: PBKDF2-HMAC-SHA512 at 600,000 iterations, AES-256-GCM, a fresh nonce
per seal. The verifier separates a wrong key from a damaged file, as it does
at sign in. Compression happens before sealing, since ciphertext does not
compress and response bodies are mostly text.

The username, the app version and the list of sections are inside the sealed
payload. The only plaintext is the KDF parameters and salt, which are useless
without the password.

## The key

An export is sealed with the identity's own key — the one its sign in
password derives — so making one asks for nothing. The key never leaves the
process holding it: `MDTClient.Vault.Keyring` is one of the per-identity
processes `Vault.Store` starts at unlock, and it seals and opens on request.
It also keeps the salt and KDF parameters from `vault.json`, which go into the
file's header.

Opening follows from that:

* **By default** the file is opened with the signed in identity's key, again
  through the keyring. That works for a file this identity exported under its
  current password, which is the common case, and asks for nothing.
* **With a password** the key is derived again from the header's salt. That
  opens the file anywhere the password is known: a profile recreated on a new
  machine (same username and password, but a new random salt, so a different
  key), or — once passwords can change — a file exported under an old one.

When the default fails, the page says so and asks for the password the file
was exported with. Nothing stops importing into a different identity from the
one that exported the file, given its password; the preview says whose file
it is before anything changes.

An export is exactly as strong as the vault it came from — the same password,
salt and iterations — and, like the vault, unreadable once the password is
forgotten.

## What an import trusts

The payload is decoded with `binary_to_term/1` without `:safe`, for the reason
`MDTClient.Vault.open/2` gives: `:safe` refuses atoms a fresh VM has not
loaded yet, which includes our own struct names. It runs only after the
payload has authenticated, so the file was written by someone holding its
key.

Unlike a vault file, an export can come from elsewhere, so that is someone
other than the user if they were given both a file and its password. Such a
file can hold arbitrary terms: at worst it exhausts the atom table, and it can
carry funs, since a `Req.Request` legitimately contains some. Nothing in MDT
calls an imported request's functions — reopening a history entry rebuilds
its request from the editor fields — and the HTTP participant checks that
each entry is the structs it expects. Treat importing someone else's file
like running their code.

The header is read before anything is authenticated, so its KDF parameters
are bounded: only the known algorithm and key length, and at most 10,000,000
iterations, so a file cannot make the app hang deriving a key.

## Files on disk

The server runs on this machine and reads and writes the files itself; the
page deals only in paths. The desktop app picks them with the dialog plugin's
save and open dialogs (`dialog:allow-save` and `dialog:allow-open` in
`src-tauri/capabilities/local-server.json`). In a plain browser the path is
typed.

The page offers `~/mdt-export-<username>-<date>.mdtexport`
(`Transfer.filename/2`), dated by the machine's local clock, since an export
only opens for the identity that made it or someone holding its password.
Only characters safe in a file name are kept from the username.

An export is written to a temporary file beside the target and renamed into
place, so a failed export cannot destroy an earlier one at the same path. A
path without an extension gets `.mdtexport`.

## Deliberately not built

**No partial import.** Every section the build understands is imported, in
the one mode chosen. `Plan` already lists sections separately, so choosing
among them — or a mode per section — is a UI change rather than a format one.

**No merge report.** The preview says what the file holds, not how much of it
is new. Participants would need a dry-run callback to say so.

**No scheduled exports.** Every export is made by hand. Since exports need no
password, one could be written on a timer while the vault is unlocked.

**Everything in memory.** Export and import hold the whole history in memory
a few times over, as the vault's periodic write already does. Streaming
sections would need a different format.
