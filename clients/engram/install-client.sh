#!/usr/bin/env bash
# Cliente del hub de engram (PC, laptop). Dos fases:
#
#   ./install-client.sh prepare <client-id> <lan|zt>
#       Config, CA, token, llave de grants, scripts y units. No toca el binario
#       de engram ni el DB: se puede ejecutar con Claude abierto.
#       lan: el cliente vive en casa (PC) y va a https://<IP LAN del hub>.
#       zt:  el cliente viaja (laptop) y va por ZeroTier a https://<IP overlay>.
#
#   ./install-client.sh migrate
#       Con Claude Code CERRADO. Backup del DB, instala engram v3 (lo que migra
#       el esquema), normaliza los datos legacy, activa el autosync y enrola.
#
# Requisitos: su pubkey de grants en engram_grant_keys y, en modo zt, el cliente
# unido a la red ZeroTier del hub y autorizado (zerotier_members en
# ansible/group_vars/engram.yml). `prepare` imprime lo que falte.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
conf_dir="$HOME/.config/engram-hub"
conf="$conf_dir/config.env"
bin_dir="$HOME/.local/bin"
units_dir="$HOME/.config/systemd/user"
stage="$HOME/.local/share/engram-hub"

die() { echo "error: $*" >&2; exit 1; }
pin() { sed -n "s/^$1: \"\(.*\)\"$/\1/p" "$repo/ansible/group_vars/all.yml"; }
cfg() { sed -n "s/^$1=//p" "$conf"; }

# Versión y checksum salen del mismo sitio que los del servidor: las versiones
# se fijan en group_vars/all.yml y en ningún otro sitio.
version="$(pin engram_version)"
sha256="$(pin engram_sha256)"
[ -n "$version" ] && [ -n "$sha256" ] || die "no encuentro engram_version/engram_sha256 en group_vars/all.yml"

hub_ssh() {
  ssh -i "$HOME/.ssh/homelab" -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      "debian@$(cfg ENGRAM_HUB_LAN)" "$@"
}

prepare() {
  local id="${1:-}" mode="${2:-}"
  [ -n "$id" ] && [[ "$mode" =~ ^(lan|zt)$ ]] \
    || die "uso: $0 prepare <client-id> <lan|zt>   (p. ej. pc-ph lan, laptop-ph zt)"
  [ "$(uname -sm)" = "Linux x86_64" ] || die "solo hay checksum fijado para linux_amd64"

  # 1. Binario de la versión fijada, verificado. Fuera del PATH hasta migrate.
  mkdir -p "$stage"
  local tgz="$stage/engram_${version}_linux_amd64.tar.gz"
  if [ ! -x "$stage/engram-$version" ]; then
    curl -fsSL -o "$tgz" \
      "https://github.com/Gentleman-Programming/engram/releases/download/v$version/engram_${version}_linux_amd64.tar.gz"
    echo "$sha256  $tgz" | sha256sum -c --quiet
    tar -xzf "$tgz" -C "$stage" engram
    mv "$stage/engram" "$stage/engram-$version"
    rm -f "$tgz"
  fi

  # 2. Config.
  mkdir -p "$conf_dir"
  chmod 700 "$conf_dir"
  if [ ! -f "$conf" ]; then
    sed -e "s|@HOME@|$HOME|g" -e "s|^ENGRAM_CLIENT_ID=.*|ENGRAM_CLIENT_ID=$id|" \
      "$here/config.env.example" > "$conf"
  fi
  chmod 600 "$conf"
  [ "$(cfg ENGRAM_CLIENT_ID)" = "$id" ] || die "$conf ya existe con otro ENGRAM_CLIENT_ID"
  local hub_ip
  if [ "$mode" = lan ]; then hub_ip="$(cfg ENGRAM_HUB_LAN)"; else hub_ip="$(cfg ENGRAM_HUB_ZT)"; fi
  sed -i "s|^ENGRAM_CLOUD_SERVER=.*|ENGRAM_CLOUD_SERVER=https://$hub_ip|" "$conf"

  # 3. CA del hub, sumada a la del sistema solo para el proceso engram.
  local ca="$conf_dir/hub-root.crt"
  if [ -f "$repo/ansible/artifacts/engram/hub-root.crt" ]; then
    cp "$repo/ansible/artifacts/engram/hub-root.crt" "$ca"
  elif [ ! -f "$ca" ]; then
    hub_ssh 'sudo cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt' > "$ca" \
      || die "no tengo la CA del hub: ejecuta el playbook o copia hub-root.crt a $conf_dir"
  fi
  cat /etc/ssl/certs/ca-certificates.crt "$ca" > "$conf_dir/ca-bundle.pem"

  # 4. Token: se recoge una vez del hub y se borra de allí.
  if [ -z "$(cfg ENGRAM_CLOUD_TOKEN)" ]; then
    local tok
    tok="$(hub_ssh "sudo cat /etc/engram/pickup/$id.tok && sudo rm /etc/engram/pickup/$id.tok" || true)"
    if [[ "$tok" =~ ^egc_[A-Za-z0-9_-]{40,}$ ]]; then
      sed -i "s|^ENGRAM_CLOUD_TOKEN=.*|ENGRAM_CLOUD_TOKEN=$tok|" "$conf"
      echo "token de $id recogido"
    else
      echo "AVISO: no pude recoger el token de $id (¿está en engram_client_tokens y se ejecutó el playbook?)." >&2
      echo "       Ponlo a mano en ENGRAM_CLOUD_TOKEN de $conf" >&2
    fi
  fi

  # 5. Llave para pedir grants (comando forzado en el hub).
  local key="$HOME/.ssh/engram-grant_$id"
  [ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -C "engram-grant $id" -f "$key"

  # 6. Scripts y units.
  mkdir -p "$bin_dir" "$units_dir"
  install -m 0755 "$here/engram-enroll" "$here/engram-hub-backup-pull" "$bin_dir/"
  install -m 0644 "$here"/systemd/* "$units_dir/"
  systemctl --user daemon-reload

  echo
  echo "== Falta en ansible/group_vars/engram.yml (y re-ejecutar el playbook) =="
  echo "engram_grant_keys:"
  echo "  - \"$(cat "$key.pub")\""
  if [ "$mode" = lan ]; then
    : # Sin overlay: el hub acepta el 443 desde la LAN.
  elif command -v zerotier-cli >/dev/null; then
    echo "zerotier_members:"
    echo "  $id: { id: \"$(sudo zerotier-cli info | awk '{print $3}')\", authorized: true }"
    echo
    echo "== Opcional: pista de camino directo cuando esté en casa (root) =="
    echo "Con una VPN que se lleva la ruta por defecto (Surfshark/WireGuard), ZeroTier"
    echo "cae a relay TCP y no descubre el hub aunque esté en la misma LAN (visto en"
    echo "el PC el 2026-10-11). Fuera de casa la pista no responde y no estorba."
    echo "  sudo install -m 0644 $here/zerotier-local.conf /var/lib/zerotier-one/local.conf"
    echo "  sudo systemctl restart zerotier-one"
    echo "(si ya existe un local.conf, fusiona la clave \"virtual\" a mano)"
  else
    echo "zerotier-one no está instalado: instálalo y únete con"
    echo "  sudo zerotier-cli join <network id del resumen del playbook>"
  fi
  echo
  echo "Después: cerrar Claude Code y ejecutar  $0 migrate"
}

migrate() {
  [ -f "$conf" ] || die "falta $conf: ejecuta antes '$0 prepare <client-id>'"
  [ -n "$(cfg ENGRAM_CLOUD_TOKEN)" ] || die "ENGRAM_CLOUD_TOKEN vacío en $conf"
  [ -x "$stage/engram-$version" ] || die "falta el binario preparado: '$0 prepare'"

  # Ningún engram vivo: un mcp de la versión vieja con el DB abierto mientras
  # la v3 migra el esquema es justo lo que no hay que probar.
  systemctl --user stop engram-hub.service 2>/dev/null || true
  if pgrep -x engram >/dev/null; then
    pgrep -a -x engram >&2
    die "hay procesos engram vivos: cierra Claude Code (y para 'engram serve') y repite"
  fi

  local data db stamp
  data="$(cfg ENGRAM_DATA_DIR)"
  db="$data/engram.db"
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$data"

  if [ -f "$db" ]; then
    sqlite3 "$db" ".backup '$db.pre-hub-$stamp'"
    echo "backup: $db.pre-hub-$stamp"
  fi

  install -m 0755 "$stage/engram-$version" "$bin_dir/engram"
  hash -r
  [ "$(command -v engram)" = "$bin_dir/engram" ] \
    || die "'engram' en el PATH es $(command -v engram), no $bin_dir/engram: corrige el orden del PATH"
  set -a; . "$conf"; set +a

  # Abrir el DB una vez con la v3 migra el esquema.
  engram stats --all >/dev/null

  if [ -f "$db" ] && [ "$(sqlite3 "$db" "SELECT count(*) FROM sessions WHERE id = 'manual-save'")" != 0 ]; then
    local map="$here/legacy-map.$(cfg ENGRAM_CLIENT_ID).sql"
    [ -f "$map" ] && sqlite3 "$db" ".read $map"
    local problems
    problems="$(sqlite3 "$db" ".parameter set :home '$HOME'" ".read $here/normalize-legacy.sql")"
    if [ -n "$problems" ]; then
      echo "$problems" >&2
      die "datos legacy sin normalizar (ver arriba). El backup está en $db.pre-hub-$stamp"
    fi
    echo "datos legacy normalizados"
  fi

  engram cloud config --server "$(cfg ENGRAM_CLOUD_SERVER)" >/dev/null
  engram cloud status | sed -n '1,4p'

  systemctl --user enable --now engram-hub.service engram-enroll.timer
  [ -f "$HOME/.ssh/homelab" ] && systemctl --user enable --now engram-hub-backup-pull.timer

  # Primer enroll ya, sin esperar al timer.
  "$bin_dir/engram-enroll"
  echo
  echo "Listo. Estado del autosync: curl -s localhost:7437/sync/status?project=<proyecto>"
}

case "${1:-}" in
  prepare) shift; prepare "$@" ;;
  migrate) migrate ;;
  *) die "uso: $0 prepare <client-id> | migrate" ;;
esac
