#!/usr/bin/env bash
# Published separately as RusAbk/noomic-install/install.sh. No application
# source or credentials belong in this public bootstrap.
noomic_install() {
  set -euo pipefail
  umask 077
  local installation=/opt/noomic selected_release='' unattended=false
  local repository=RusAbk/math-craft temporary='' revision='' release_root=''
  local -a deploy_args=()
  note() { printf '\nНумик: %s\n' "$*"; }
  fail() { printf '\nНумик: %s\n' "$*" >&2; exit 1; }
  while (( $# )); do
    case "$1" in
      --help|-h)
        printf '%s\n' 'Нумик — установка и обновление одной командой.' \
          'Ubuntu 22.04/24.04/26.04 и Debian 12/13, Linux amd64.' \
          '--install-dir PATH   каталог установки (по умолчанию /opt/noomic)' \
          '--release server-SHA установить конкретный проверенный выпуск' \
          '--yes                без вопросов; NOOMIC_ADMIN_* и GH_TOKEN из окружения' \
          '--web-domain DOMAIN --api-domain DOMAIN --email EMAIL' \
          '--http-port PORT --https-port PORT'
        return 0 ;;
      --yes) unattended=true; deploy_args+=(--yes) ;;
      --install-dir|--release|--web-domain|--api-domain|--email|--http-port|--https-port)
        (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || fail "Нет значения для $1"
        case "$1" in
          --install-dir) installation="$2" ;;
          --release) selected_release="$2" ;;
          *) deploy_args+=("$1" "$2") ;;
        esac
        shift ;;
      *) fail "Неизвестный параметр: $1" ;;
    esac
    shift
  done
  [[ "$installation" =~ ^/[a-zA-Z0-9_/-]+$ && "$installation" != / && "$installation" != */../* && "$installation" != */.. ]] || fail 'Некорректный каталог установки'
  [[ -z "$selected_release" || "$selected_release" =~ ^server-[a-f0-9]{40}$ ]] || fail 'Некорректный выпуск: нужен server-<полный SHA>'
  [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || fail 'Опубликованные контейнеры рассчитаны на Linux amd64 (x86_64)'

  # All script bytes have been parsed before entering this function. Piped
  # installation must read prompts from the terminal, never from curl's pipe.
  if [[ "$unattended" == false ]]; then
    { exec </dev/tty; } 2>/dev/null || fail 'Для вопросов нужен терминал; для автоматизации используйте --yes'
  fi
  if (( EUID != 0 )); then
    command -v sudo >/dev/null || fail 'Запустите команду от root: sudo отсутствует'
    temporary="$(mktemp /tmp/noomic-bootstrap.XXXXXX)"
    # Serialize only our own complete function, not shell startup files or
    # imported user functions. This also works when invoked as curl | bash.
    declare -f noomic_install > "$temporary"
    printf '\nnoomic_install "$@"\n' >> "$temporary"
    local result=0
    local -a again=(--install-dir "$installation" "${deploy_args[@]}")
    [[ -z "$selected_release" ]] || again+=(--release "$selected_release")
    sudo --preserve-env=GH_TOKEN,GITHUB_TOKEN,NOOMIC_ADMIN_NAME,NOOMIC_ADMIN_EMAIL,NOOMIC_ADMIN_PASSWORD bash "$temporary" "${again[@]}" || result=$?
    rm -f -- "$temporary"
    return "$result"
  fi

  local ID='' VERSION_ID='' VERSION_CODENAME='' UBUNTU_CODENAME=''
  [[ -r /etc/os-release ]] || fail 'Не удалось определить Linux'
  # shellcheck source=/dev/null
  . /etc/os-release
  case "$ID:$VERSION_ID" in
    ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:12|debian:13) ;;
    *) fail "Пока поддерживаются Ubuntu 22.04/24.04/26.04 и Debian 12/13; обнаружено $ID $VERSION_ID" ;;
  esac
  local codename="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
  [[ "$codename" =~ ^[a-z]+$ ]] || fail 'Не удалось определить выпуск Linux'

  temporary="$(mktemp -d /tmp/noomic-bootstrap.XXXXXX)"
  # Do not discard a user's existing credential store. Ours is private to this
  # installation, owned by root, and reused for unattended future updates.
  local cleanup_command
  printf -v cleanup_command 'rm -rf -- %q' "$temporary"
  # Capture the path now: this local variable is gone when EXIT unwinds a failure.
  # shellcheck disable=SC2064
  trap "$cleanup_command" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [[ ! -e "$installation/current" || -L "$installation/current" ]] || fail 'current должен быть ссылкой на выпуск, а не каталогом'
  install -d -m 700 "$installation/deployment"
  # flock itself is installed below on minimal systems; acquiring the lock
  # immediately after installing it also serializes all application changes.
  note 'Проверяем системные зависимости'
  local -a missing=()
  local spec binary package
  for spec in curl:curl python3:python3 flock:util-linux tar:tar gzip:gzip cmp:diffutils grep:grep; do
    binary="${spec%%:*}"; package="${spec#*:}"
    command -v "$binary" >/dev/null || missing+=("$package")
  done
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
  if (( ${#missing[@]} )); then
    apt-get -o DPkg::Lock::Timeout=180 update
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends "${missing[@]}"
  fi
  exec 9>"$installation/deployment/bootstrap.lock"
  flock -n 9 || fail 'Другой установщик уже работает с этим каталогом'

  github_cli_ready() {
    command -v gh >/dev/null || return 1
    local version
    version="$(gh --version)"
    [[ "$version" =~ gh\ version\ ([0-9]+)\.([0-9]+) ]] || return 1
    (( BASH_REMATCH[1] > 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] >= 46) ))
  }
  if ! github_cli_ready; then
    note 'Устанавливаем GitHub CLI для входа по коду в браузере'
    if ! grep -qrsE '^[^#]*https://cli.github.com/packages([ /]|$)' /etc/apt/sources.list.d/; then
      install -d -m 0755 /etc/apt/keyrings
      curl --proto '=https' --tlsv1.2 --fail --show-error --silent --location --retry 3 \
        https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$temporary/github.gpg"
      install -m 0644 "$temporary/github.gpg" /etc/apt/keyrings/noomic-github-cli.gpg
      printf '%s\n' 'deb [arch=amd64 signed-by=/etc/apt/keyrings/noomic-github-cli.gpg] https://cli.github.com/packages stable main' \
        > /etc/apt/sources.list.d/noomic-github-cli.list
    fi
    # Package hooks can start long-lived services. Only this shell may own the lock.
    apt-get -o DPkg::Lock::Timeout=180 update 9>&-
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends gh 9>&-
  fi
  github_cli_ready || fail 'Не удалось установить GitHub CLI ≥ 2.46'

  docker_ready() {
    command -v docker >/dev/null || return 1
    local version
    version="$(docker compose version --short 2>/dev/null)" || return 1
    [[ "$version" =~ ^v?([0-9]+)\.([0-9]+) ]] || return 1
    (( BASH_REMATCH[1] > 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] >= 24) ))
  }
  if ! docker_ready; then
    # Never remove another application's runtime to force a package migration.
    local conflicts=''
    for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
      if [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" == 'install ok installed' ]]; then conflicts+=" $package"; fi
    done
    [[ -z "$conflicts" ]] || fail "Найден существующий Docker/runtime с несовместимыми пакетами:$conflicts. Автоматическое удаление отключено; нужен Docker с Compose ≥ 2.24."
    note 'Устанавливаем Docker Engine и Compose из официального репозитория Docker'
    if ! grep -qrsE "^[^#]*https://download.docker.com/linux/$ID([ /]|$)" /etc/apt/sources.list.d/; then
      install -d -m 0755 /etc/apt/keyrings
      curl --proto '=https' --tlsv1.2 --fail --show-error --silent --location --retry 3 \
        "https://download.docker.com/linux/$ID/gpg" -o "$temporary/docker.asc"
      install -m 0644 "$temporary/docker.asc" /etc/apt/keyrings/noomic-docker.asc
      cat > /etc/apt/sources.list.d/noomic-docker.sources <<SOURCES
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $codename
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/noomic-docker.asc
SOURCES
    fi
    apt-get -o DPkg::Lock::Timeout=180 update 9>&-
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 9>&-
  fi
  docker_ready || fail 'Не удалось установить Docker с Compose ≥ 2.24'
  if ! docker info >/dev/null 2>&1; then
    if [[ -d /run/systemd/system ]]; then systemctl enable --now docker 9>&-
    elif command -v service >/dev/null; then service docker start 9>&-
    else fail 'Docker установлен, но менеджер служб не найден'; fi
    local attempt
    for ((attempt=0; attempt<30; attempt++)); do docker info >/dev/null 2>&1 && break; sleep 1; done
  fi
  docker info >/dev/null || fail 'Служба Docker не запустилась'

  export GH_CONFIG_DIR="$installation/deployment/github-auth"
  export DOCKER_CONFIG="$installation/deployment/registry-auth"
  install -d -m 700 "$GH_CONFIG_DIR" "$DOCKER_CONFIG"
  if ! gh api "repos/$repository" --silent >/dev/null 2>&1; then
    [[ "$unattended" == false ]] || fail 'Для закрытого проекта задайте GH_TOKEN с доступом к репозиторию и read:packages'
    [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]] || fail 'Переданный токен не имеет доступа к проекту'
    note 'Подтвердите вход GitHub по коду ниже. Войти нужно аккаунтом с доступом к проекту.'
    # Non-terminal stdin suppresses the unrelated Git credential setup prompt.
    # GitHub still prints the device code and waits for browser authorization.
    GH_BROWSER=true gh auth login --hostname github.com --git-protocol https --web --scopes read:packages </dev/null
  fi
  gh api "repos/$repository" --silent >/dev/null || fail 'Аккаунту GitHub недоступен проект'
  local login
  login="$(gh api user --jq .login)"
  { if [[ -n "${GH_TOKEN:-}" ]]; then printf '%s' "$GH_TOKEN"
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then printf '%s' "$GITHUB_TOKEN"
    else gh auth token --hostname github.com; fi; } | docker login ghcr.io --username "$login" --password-stdin

  if [[ -z "$selected_release" ]]; then
    selected_release="$(gh api "repos/$repository/releases/latest" --jq .tag_name)" || fail 'Опубликованный установочный выпуск пока не найден'
  fi
  [[ "$selected_release" =~ ^server-([a-f0-9]{40})$ ]] || fail 'Неожиданный формат опубликованного выпуска'
  revision="${BASH_REMATCH[1]}"
  note "Скачиваем проверенный выпуск ${revision:0:7}"
  gh release download "$selected_release" --repo "$repository" --pattern noomic-deploy.tar.gz --pattern release.json --dir "$temporary"

  # Validate the manifest and every tar member before extracting or running
  # anything. A corrupt download cannot touch config, volumes or live files.
  python3 - "$temporary" "$revision" <<'PY'
import hashlib,json,re,sys,tarfile
from pathlib import Path
root=Path(sys.argv[1]); revision=sys.argv[2]
manifest=json.loads((root/'release.json').read_text())
expected={'schema':1,'repository':'RusAbk/math-craft','commit':revision,'image_tag':'sha-'+revision,'architecture':'amd64','archive':'noomic-deploy.tar.gz'}
if any(manifest.get(k)!=v for k,v in expected.items()):raise SystemExit('Неверный манифест выпуска')
archive=root/'noomic-deploy.tar.gz'
if not re.fullmatch('[a-f0-9]{64}',str(manifest.get('sha256',''))) or hashlib.sha256(archive.read_bytes()).hexdigest()!=manifest['sha256']:
 raise SystemExit('Контрольная сумма установочного архива не совпала')
required={'compose.yaml','docker/Caddyfile','docker/compose.env.example','deployment/deploy.sh','deployment/configure.py','deployment/README.md'}
with tarfile.open(archive) as bundle:
 members=bundle.getmembers()
 if {m.name for m in members}!=required or len(members)!=len(required) or any(not m.isfile() or m.size>1024*1024 for m in members):
  raise SystemExit('Неожиданное содержимое установочного архива')
 for member in members:
  target=root/'verified'/member.name;target.parent.mkdir(parents=True,exist_ok=True)
  with bundle.extractfile(member) as source:target.write_bytes(source.read())
PY
  release_root="$installation/releases/$revision"
  install -d -m 0755 "$installation/releases"
  # Stage an entire verified directory and rename it, never unpack over live
  # configuration. The existing config is explicitly shared across releases.
  local stage
  stage="$(mktemp -d "$installation/releases/.staging.XXXXXX")"
  cp -R "$temporary/verified/." "$stage/"
  if [[ -e "$release_root" ]]; then
    local relative
    for relative in compose.yaml docker/Caddyfile docker/compose.env.example deployment/deploy.sh deployment/configure.py deployment/README.md; do
      cmp -s "$stage/$relative" "$release_root/$relative" || {
        rm -rf -- "$stage"
        fail 'Каталог этого выпуска уже изменён; исходники автоматически не перезаписываются'
      }
    done
    rm -rf -- "$stage"
  else mv -- "$stage" "$release_root"; fi
  chmod 0755 "$release_root"
  unset GH_TOKEN GITHUB_TOKEN
  note 'Настраиваем приложение, сохраняем существующие данные и запускаем контейнеры'
  bash "$release_root/deployment/deploy.sh" --pull --env-file "$installation/deployment/config.env" \
    --version "sha-$revision" "${deploy_args[@]}"
  ln -sfn "$release_root" "$installation/.current-next"
  mv -Tf "$installation/.current-next" "$installation/current"
  note "Готово. Установлена версия ${revision:0:7}. Повтор этой же команды обновляет приложение."
  rm -rf -- "$temporary"
  trap - EXIT INT TERM
}
noomic_install "$@"
