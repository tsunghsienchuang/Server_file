#!/bin/bash
set -euo pipefail

ssh_host=${CODEX_PREVIEW_HOST:-}
ssh_port=${CODEX_PREVIEW_PORT:-22}
preview_url='http://127.0.0.1:8877/'

valid_ipv6_address() {
  local address=$1 zone tail first second third fourth octet left right colons
  local left_count=0 right_count=0
  local groups='^[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4})*$'
  local decimal='^(0|[1-9][0-9]{0,2})$'
  local zone_pattern='^[A-Za-z0-9_.-]+$'
  local ipv4_pattern='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
  local LC_ALL=C

  if [[ "$address" == *%* ]]; then
    zone=${address#*%}
    [[ "$zone" =~ $zone_pattern ]] || return 1
    address=${address%%%*}
  fi
  [[ "$address" == *:* && "$address" != *:::* ]] || return 1
  if [[ "$address" == *.* ]]; then
    tail=${address##*:}
    [[ "$tail" =~ $ipv4_pattern ]] || return 1
    IFS=. read -r first second third fourth <<< "$tail"
    for octet in "$first" "$second" "$third" "$fourth"; do
      [[ "$octet" =~ $decimal ]] && (( 10#$octet <= 255 )) || return 1
    done
    address=${address%:*}:0:0
  fi
  if [[ "$address" == *::* ]]; then
    left=${address%%::*}
    right=${address#*::}
    if [[ -n "$left" ]]; then
      [[ "$left" =~ $groups ]] || return 1
      colons=${left//[^:]/}
      left_count=$((${#colons} + 1))
    fi
    if [[ -n "$right" ]]; then
      [[ "$right" =~ $groups ]] || return 1
      colons=${right//[^:]/}
      right_count=$((${#colons} + 1))
    fi
    (( left_count + right_count < 8 ))
  else
    [[ "$address" =~ $groups ]] || return 1
    colons=${address//[^:]/}
    (( ${#colons} == 7 ))
  fi
}

valid_ssh_target() {
  local username_pattern='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$'
  local hostname_pattern='^[A-Za-z0-9][A-Za-z0-9_-]{0,62}(\.[A-Za-z0-9][A-Za-z0-9_-]{0,62})*\.?$'
  local LC_ALL=C
  [[ "$ssh_host" == *@* && "$ssh_user" =~ $username_pattern ]] || return 1
  if [[ "$ssh_hostname" == \[*\] ]]; then
    ssh_hostname=${ssh_hostname:1:${#ssh_hostname}-2}
    valid_ipv6_address "$ssh_hostname"
  elif [[ "$ssh_hostname" == *:* ]]; then
    valid_ipv6_address "$ssh_hostname"
  else
    [[ ${#ssh_hostname} -le 254 && "$ssh_hostname" =~ $hostname_pattern ]]
  fi
}

ssh_user=${ssh_host%@*}
ssh_hostname=${ssh_host##*@}
if [[ -z "$ssh_host" ]]; then
  printf '請將 CODEX_PREVIEW_HOST 設為 SSH 帳號@主機。\n' >&2
  exit 2
fi
if ! valid_ssh_target; then
  printf 'SSH 目標格式無效，請使用「帳號@主機名稱或 IP」。\n' >&2
  exit 2
fi
if [[ ! "$ssh_port" =~ ^[0-9]{1,5}$ ]] || (( 10#$ssh_port < 1 || 10#$ssh_port > 65535 )); then
  printf 'SSH 連接埠必須是 1 到 65535 的數字。\n' >&2
  exit 2
fi
ssh_port=$((10#$ssh_port))
if (( $# > 1 )); then
  printf '用法：設定 CODEX_PREVIEW_HOST 後執行 %s [遠端資料夾的絕對路徑或 ~/ 路徑]\n' "${0##*/}" >&2
  exit 2
fi

session_id=$(/usr/bin/uuidgen)
socket_path="/tmp/codex-preview-${session_id}/http.sock"
remote_directory=${1-${CODEX_PREVIEW_REMOTE_DIR:-}}
if (( $# == 1 )) && [[ -z "$remote_directory" ]]; then
  printf '請輸入遠端資料夾，或省略參數以使用預設位置。\n' >&2
  exit 2
fi
directory_arg=$(printf '%s' "$remote_directory" | /usr/bin/base64 | /usr/bin/tr -d '\r\n')

launcher_directory=$(cd -P "$(dirname "$0")" && pwd)
preview_source="$launcher_directory/preview_server.py"
if [[ ! -r "$preview_source" ]]; then
  printf 'Server Files: preview_server.py is missing.\n' >&2
  exit 1
fi
server_arg=$(/usr/bin/gzip -9c "$preview_source" | /usr/bin/base64 | /usr/bin/tr -d '\r\n')
remote_command="exec python3 -u -c 'import base64,gzip,sys; exec(compile(gzip.decompress(base64.b64decode(sys.argv.pop(1))), \"<codex-preview>\", \"exec\"))' '$server_arg' '$socket_path' '$directory_arg' '$ssh_host' '$ssh_port'"
if (( ${#remote_command} >= 131000 )); then
  printf 'Server Files: the bundled preview worker exceeds the SSH command size limit.\n' >&2
  exit 1
fi

printf '連線到 %s（SSH 連接埠 %s）\n' "$ssh_host" "$ssh_port"
printf '遠端報告資料夾：%s\n' "${remote_directory:-~/reports（若不存在則使用暫存資料夾）}"
printf '預覽網址：%s\n' "$preview_url"
printf '預覽時請保持這個視窗開著，按 Control-C 可停止。\n\n'

strict_host_key=yes
if [[ "${CODEX_PREVIEW_INTERACTIVE:-0}" == 1 ]]; then
  strict_host_key=ask
fi
ssh_options=(
  -T
  -x
  -l "$ssh_user"
  -p "$ssh_port"
  -o "StrictHostKeyChecking=$strict_host_key"
  -o ExitOnForwardFailure=yes
  -o ConnectTimeout=12
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -o ForwardAgent=no
  -o GatewayPorts=no
  -o PermitLocalCommand=no
  -o ControlMaster=no
  -o ControlPath=none
  -L "127.0.0.1:8877:$socket_path"
  -L "127.0.0.1:8878:$socket_path"
)
if [[ "${CODEX_PREVIEW_INTERACTIVE:-0}" == 1 ]]; then
  if [[ -z "${SSH_ASKPASS:-}" || ! -x "$SSH_ASKPASS" ]]; then
    printf '無法使用 App 的 SSH 登入提示。\n' >&2
    exit 2
  fi
  export SSH_ASKPASS_REQUIRE=force LC_ALL=C
  preferred_auth=publickey,keyboard-interactive,password
  if [[ -n "${CODEX_PREVIEW_ASKPASS_FILE:-}" ]]; then
    preferred_auth=keyboard-interactive,password,publickey
  fi
  ssh_options+=(
    -o BatchMode=no
    -o UseKeychain=yes
    -o PubkeyAuthentication=yes
    -o PasswordAuthentication=yes
    -o KbdInteractiveAuthentication=yes
    -o "PreferredAuthentications=$preferred_auth"
    -o NumberOfPasswordPrompts=1
  )
elif [[ "${CODEX_PREVIEW_AUTH:-}" == password ]]; then
  if [[ -z "${SSH_ASKPASS:-}" || ! -x "$SSH_ASKPASS" ]]; then
    printf '無法使用 App 的 SSH 密碼提示。\n' >&2
    exit 2
  fi
  export SSH_ASKPASS_REQUIRE=force
  ssh_options+=(
    -o BatchMode=no
    -o PubkeyAuthentication=no
    -o PasswordAuthentication=yes
    -o KbdInteractiveAuthentication=yes
    -o PreferredAuthentications=keyboard-interactive,password
    -o NumberOfPasswordPrompts=1
  )
elif [[ "${CODEX_PREVIEW_BATCH:-0}" == 1 ]]; then
  ssh_options+=(-o BatchMode=yes -o UseKeychain=yes -o AddKeysToAgent=yes)
fi
exec /usr/bin/ssh "${ssh_options[@]}" -- "$ssh_hostname" "$remote_command"
