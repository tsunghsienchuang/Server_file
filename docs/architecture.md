# Architecture

Server Files opens an SSH session and serves the file browser over two loopback ports. The SSH session launches a temporary Python worker as the authenticated remote account. The macOS menu bar app and Windows console launcher both forward the local TCP ports to one private Unix socket on the server.

## Browser origins and file scope

| Local origin | Directory with an explicit scope | Directory with a blank scope | Operations |
| --- | --- | --- | --- |
| `http://127.0.0.1:8878` | Selected remote directory | Remote account’s home directory | Browse, preview, search, transfer, create, rename, move, tag, edit, move files to trash |
| `http://127.0.0.1:8877` | Selected remote directory | Remote `~/reports` if present and inside the remote home, otherwise an empty temporary directory | Read-only browsing and report preview |

Choose an existing absolute path or a path beginning with `~/` to limit the exposed workspace. The remote operating system applies the SSH account’s file permissions. Folder and file writes use descriptor-relative operations and reject symlink traversal. Text editing supports `.py`, `.md`, `.txt`, and `.json` up to 2 MiB, with conflict detection if the remote file changes during editing. Trash operations move a file into `.codex-preview-trash/` under the Files root so it can be recovered over SSH. Color tags are stored in private metadata under the Files root.

## Connection and trust boundaries

- **SSH.** The app uses the system OpenSSH client and standard `known_hosts` handling. Verify a new host’s fingerprint with the server administrator before accepting it. Stop and investigate any changed-host-key warning. The server needs Python 3.10+ and OpenSSH with local forwarding permitted. For servers with restricted forwarding, verify that `AllowTcpForwarding` and `AllowStreamLocalForwarding` both allow local connections.
- **Temporary worker.** The Python process listens on a Unix socket in a private remote temporary directory. The launchers bind the local ports to `127.0.0.1`. The launchers stream the compressed worker over SSH standard input to stay within process argument limits. The managed session closes the worker and cleans up the socket on a normal stop.
- **Local browser.** Local processes that can reach the loopback ports are inside the trust boundary. Writes require the Files origin and a per-session token. Recently opened file history is stored in the browser and scoped to the SSH connection target and Files root. Use the panel’s Clear button to remove it.
- **Credentials.** The macOS app stores recent connection settings locally and saves passwords to Keychain on request. The Windows launcher delegates authentication prompts to the OpenSSH console. Existing SSH keys and agents can be used through OpenSSH.
- **Remote HTML.** The Reports origin can render HTML reports in a sandbox that allows scripts with an opaque origin. Some same-origin fetches and app integrations may fail in that sandbox. HTML reports can still initiate browser requests, so open reports from sources you trust. The Files origin serves remote HTML as a download or as plain text in quick preview.

## Search and covers

Name and path search walks subfolders and returns up to 200 matches. Content search scans eligible UTF-8 text files within the current directory tree. It limits each file to 2 MiB and each request to 4,096 candidate files, 64 MiB of text reads, and 50,000 directory entries. Results can be partial when a budget is reached. Content is read on demand.

Icon view fetches covers as cards enter the viewport. Supported raster files have byte and pixel limits, and text snippets are inserted as plain text. PDF covers use Poppler’s `pdftoppm` when available at a standard server path. Rendering is limited to the first page of PDFs up to 16 MiB, with a timeout and bounded concurrency. Unsupported files and failed covers show their file-type icon. SVG source is excluded from the cover renderer.

## Source layout

- `Sources/ServerFiles.swift` contains the native connection window, menu, SSH management, and Keychain integration.
- `Sources/ServerFilesPreview.command` starts the macOS SSH session. `Sources/windows/` contains the Windows launcher. Both use `Sources/preview_server.py` for the remote worker and web interface.
- `scripts/build.sh` assembles the universal macOS app and ZIP. `scripts/build-windows.sh` packages the x64 and ARM64 executables as separate ZIPs.
- The bundled VS Code Modern Icons paths carry their Microsoft MIT notice in the source.
