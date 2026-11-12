# Server Files

![Server Files illustration showing a Mac connected over SSH to a remote workspace, with PDF, image, and Markdown covers](docs/cover.svg)

A macOS menu bar app for browsing, previewing, and managing files on a remote machine over SSH. Open the workspace in your browser and see updated files as your tools write them.

[繁體中文快速開始](#繁體中文快速開始) · [Architecture and trust boundaries](docs/architecture.md)

## Download

[Download Server Files 1.0.0 for macOS](../../releases/download/v1.0.0/Server-Files-1.0.0-macOS-universal.zip) · [SHA256SUMS](../../releases/download/v1.0.0/SHA256SUMS) · [All releases](../../releases)

The universal app runs on **macOS 13 or later**, on Apple silicon and Intel Macs. The server needs a Unix environment with **Python 3.10+** and an OpenSSH server that allows Unix socket forwarding from the client. Poppler’s `pdftoppm` is optional for PDF cover previews.

## Quick start

1. Download the ZIP and `SHA256SUMS` to the same folder. In that folder, run `shasum -a 256 -c SHA256SUMS` to verify the ZIP.
2. Unzip the archive and open **Server Files.app**. This release uses ad hoc signing and has no Developer ID notarization. If Gatekeeper prompts, verify the source and checksum, then follow Apple’s per-app approval instructions. [Apple Support](https://support.apple.com/en-us/102445)
3. Enter your SSH host, username, and port (default `22`). Leave the password blank when using an SSH key. If asked to trust a new host, compare the fingerprint with one from the server administrator. Saving a password in macOS Keychain is optional.
4. Leave the remote directory blank to browse your SSH account’s home directory. To scope both browser views to a specific folder, enter an existing absolute path such as `/srv/workspace` or a home-relative path such as `~/reports`.
5. Connect and use **Files** at [127.0.0.1:8878](http://127.0.0.1:8878/) or **Reports** at [127.0.0.1:8877](http://127.0.0.1:8877/) while the SSH session is active. Use the menu bar app to switch or stop connections.

## What you can do

- Browse in icon, list, or column view. Sort by modification date, size, or kind and mark files with red, green, or blue tags.
- Search filenames and paths recursively. Enable content search to scan eligible UTF-8 text files within the current folder and its subfolders. Each scan reads files up to 2 MiB, with a budget of 4,096 candidate files, 50,000 directory entries, or 64 MiB of text and a display limit of 200 results.
- Preview PDF, image, and text files. Icon view loads image and text covers as they enter view. A compatible PDF’s first page can appear as a cover when the server has Poppler installed.
- Upload files and folders, download files or ZIP archives, copy remote paths, create and rename files, edit `.py`, `.md`, and `.txt` files, and move files to a recoverable server-side trash folder.
- Switch the web interface between light and dark themes. Choose English, 繁體中文, 简体中文, 日本語, or 한국어. The native connection window uses Traditional Chinese.

## Build from source

Install the Xcode Command Line Tools on macOS and run the build script from the repository root.

```sh
./scripts/build.sh
```

The build creates the universal app, ZIP, and SHA-256 manifest in `dist/`.

Run the server smoke tests with `python3 -m unittest discover -s tests`.

## 繁體中文快速開始

Server Files 是一款 macOS 選單列 App，透過 SSH 在本機瀏覽器查看和管理伺服器檔案。Mac 需要 **macOS 13 或更新版本**，支援 Apple 晶片及 Intel。伺服器需要 **Python 3.10 以上**，且 OpenSSH 必須允許 Unix socket 轉送。若要顯示 PDF 首頁封面，可在伺服器安裝 Poppler 的 `pdftoppm`。

1. [下載 macOS 通用版 1.0.0](../../releases/download/v1.0.0/Server-Files-1.0.0-macOS-universal.zip) 和 [SHA256SUMS](../../releases/download/v1.0.0/SHA256SUMS)。在下載資料夾執行 `shasum -a 256 -c SHA256SUMS` 核對檔案。
2. 解壓縮並開啟 **Server Files.app**。此版本沒有 Developer ID 公證。若 Gatekeeper 擋下，請先核對來源和雜湊值，再依 Apple 說明對此 App 個別核准。[Apple 支援](https://support.apple.com/en-us/102445)
3. 輸入 SSH 主機、帳號和連接埠（預設 `22`）。使用 SSH 金鑰時可以把密碼留空。首次連線若出現主機指紋，請先與管理員核對。儲存密碼到 macOS 鑰匙圈是選填。
4. 遠端資料夾留空時，檔案頁會開啟 SSH 帳號的主目錄。填入 `/srv/workspace` 或 `~/reports` 這類既有路徑，可將兩個頁面限制在該資料夾。
5. 連線後可在 [127.0.0.1:8878](http://127.0.0.1:8878/) 管理檔案，或到 [127.0.0.1:8877](http://127.0.0.1:8877/) 預覽報告。檔案頁提供圖像、列表和直欄檢視，也可搜尋檔名或 UTF-8 文字內容、排序、加標籤、上下載及編輯指定的文字檔。
