#!/usr/bin/env bash
# Standalone registry updater; also works as curl .../update.sh | bash -s -- apply.
noomic_update() {
  set -euo pipefail
  umask 077
  # EXIT recovery must retain state after Bash unwinds a failed function.
  declare -g action=help installation='' env_file='' version='' feed=ghcr.io/rusabk/math-craft-update yes=false
  declare -g source_dir='' explicit=false temporary='' container='' operation='' changed=false previous_root='' root=''
  fail() { printf '\nНумик: %s\n' "$*" >&2; exit 1; }
  note() { printf '\nНумик: %s\n' "$*"; }
  if (( $# )) && [[ "$1" != --* ]]; then action="$1"; shift; fi
  while (( $# )); do
    case "$1" in
      --help|-h) action=help ;;
      --yes) yes=true ;;
      --install-dir|--env-file|--version|--feed)
        (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || fail "$1 требует значение"
        case "$1" in --install-dir) installation="$2" ;; --env-file) env_file="$2" ;; --version) version="$2";explicit=true ;; --feed) feed="$2" ;; esac
        shift ;;
      *) fail "Неизвестный параметр: $1" ;;
    esac
    shift
  done
  case "$action" in
    help) cat <<'HELP'
Нумик — обновление существующей установки
  bash update.sh check       проверить доступный выпуск, не останавливая сервер
  bash update.sh apply       скачать выпуск, сделать копию и обновить
  bash update.sh status      показать установленную версию
  bash update.sh rollback    вернуть предыдущие образы и установочные файлы
  --install-dir PATH         каталог существующей установки
  --env-file PATH            существующий файл конфигурации
  --version sha-ПОЛНЫЙ_SHA   конкретный выпуск вместо stable
  --feed IMAGE               источник пакета обновления в registry
  --yes                      без подтверждения
Откат приложения сохраняет текущую базу; SQL-дамп автоматически не импортируется.
HELP
      return ;;
    check|apply|status|rollback) ;;
    *) fail 'Команды: check, apply, status, rollback (см. --help)' ;;
  esac
  command -v python3 >/dev/null || fail 'Нужен Python 3 из первоначальной установки'
  if [[ -z "$installation" ]]; then
    if [[ -f "$PWD/deployment/config.env" ]]; then installation="$PWD"
    elif [[ -f "${BASH_SOURCE[0]:-}" ]]; then
      source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
      if [[ -f "$source_dir/deployment/config.env" ]]; then installation="$source_dir"
      elif [[ "$source_dir" == */releases/* ]]; then installation="${source_dir%/releases/*}"; fi
    fi
    if [[ -z "$installation" ]]; then
      local -a found=();local candidate
      for candidate in /opt/noomic /var/noomic; do [[ ! -f "$candidate/deployment/config.env" ]] || found+=("$candidate"); done
      (( ${#found[@]} == 1 )) || fail 'Укажите --install-dir: нужна одна существующая установка с deployment/config.env'
      installation="${found[0]}"
    fi
  fi
  installation="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$installation")"
  env_file="${env_file:-$installation/deployment/config.env}"
  env_file="$(python3 -c 'import os,sys;print(os.path.abspath(sys.argv[1]))' "$env_file")"
  [[ -f "$env_file" ]] || fail "Существующая конфигурация не найдена: $env_file. Для первой установки используйте install.sh"
  if [[ -L "$installation/current" && -f "$installation/current/compose.yaml" ]]; then root="$(readlink -f -- "$installation/current")"
  elif [[ -f "$installation/compose.yaml" ]]; then root="$installation"
  else fail 'В существующей установке не найден compose.yaml'; fi
  # No packages or system services are changed: run as the installation owner
  # with Docker access (root for installations made by install.sh).
  declare -g state_dir="$installation/deployment/updates" current="$installation/deployment/updates/current.json"
  env_get() { python3 - "$1" "${2:-$env_file}" <<'PY'
import sys
from pathlib import Path
for line in Path(sys.argv[2]).read_text().splitlines():
 key,sep,value=line.partition('=')
 if sep and key==sys.argv[1]:print(value);break
PY
  }
  json_get() { python3 - "$1" "$2" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[2]);value=json.loads(p.read_text()).get(sys.argv[1],'') if p.exists() else ''
print(str(value).lower() if isinstance(value,bool) else value)
PY
  }
  if [[ "$action" == status ]]; then
    printf 'Установлено: %s\nКаталог: %s\n' "$(env_get APP_VERSION)" "$installation"
    if [[ -f "$current" ]]; then printf 'Коммит: %s\nРезервная копия: %s\n' "$(json_get commit "$current")" "$(json_get backup "$current")"; fi
    return
  fi
  command -v docker >/dev/null || fail 'Docker не найден; сначала выполните первоначальную установку'
  [[ -n "${DOCKER_CONFIG:-}" || ! -d "$installation/deployment/registry-auth" ]] || export DOCKER_CONFIG="$installation/deployment/registry-auth"
  docker info >/dev/null || fail 'Docker недоступен'
  compose() { local files=(-f "$root/compose.yaml");[[ ! -f "$root/deployment/images.override.json" ]] || files+=(-f "$root/deployment/images.override.json");docker compose --project-directory "$root" --env-file "$env_file" "${files[@]}" "$@"; }
  atomic_copy() {
    local next
    next="$(mktemp "$(dirname -- "$2")/.noomic-copy.XXXXXX")" || return 1
    if ! cp -- "$1" "$next" || ! chmod "${3:-600}" "$next" || ! mv -f -- "$next" "$2"; then rm -f -- "$next";return 1;fi
  }
  restore_application() {
    local record="$1" backup previous had_current old_version previous_record
    backup="$(json_get backup "$record")";previous="$(json_get previous_root "$record")";had_current="$(json_get had_current "$record")";old_version="$(json_get previous_version "$record")"
    [[ -f "$backup/complete" && -f "$previous/compose.yaml" ]] || return 1
    (cd -- "$backup" && sha256sum -c checksums.sha256 >/dev/null) || return 1
    [[ "$(env_get COMPOSE_PROJECT_NAME "$backup/config.env")" == "$(env_get COMPOSE_PROJECT_NAME)" ]] || return 1
    python3 "$previous/deployment/configure.py" --env-file "$env_file" --yes --version "$old_version" || return 1
    docker compose --project-directory "$previous" --env-file "$env_file" -f "$previous/compose.yaml" -f "$backup/images.json" \
      up -d --no-deps --no-build --force-recreate --wait --wait-timeout 300 api web proxy || return 1
    if [[ "$had_current" == true ]]; then
      ln -sfn -- "$previous" "$installation/.current-next" || return 1
      mv -Tf -- "$installation/.current-next" "$installation/current" || return 1
    else rm -f -- "$installation/current" || return 1;fi
    previous_record="$(dirname -- "$backup")/previous.json"
    if [[ -f "$previous_record" ]]; then atomic_copy "$previous_record" "$current" || return 1;else rm -f -- "$current" || return 1;fi
    changed=false
  }
  finish() {
    local result=$?;trap - EXIT;set +e
    if (( result != 0 )) && [[ "$changed" == true ]]; then
      if [[ -f "$operation/backup/complete" ]]; then
        note 'Обновление не завершилось. Возвращаем предыдущие образы; текущая база сохраняется.' >&2
        restore_application "$operation/current.json" || note 'Предыдущие образы не запустились. Проверьте совместимость схемы и логи; SQL-дамп автоматически не восстановлен.' >&2
      fi
      [[ -z "$operation" ]] || note "Файлы восстановления: $operation" >&2
    fi
    [[ -z "$container" ]] || docker rm "$container" >/dev/null 2>&1
    [[ -z "$temporary" ]] || rm -rf -- "$temporary"
    exit "$result"
  }
  trap finish EXIT
  if [[ "$action" == apply || "$action" == rollback ]]; then
    mkdir -p "$state_dir"
    exec 8>"$installation/deployment/bootstrap.lock";flock -n 8 || fail 'Другой установщик уже работает'
    exec 9>"$env_file.lock";flock -n 9 || fail 'Другое развёртывание уже работает'
  fi
  confirm() { [[ "$yes" == true ]] && return 0;local answer;printf '%s [y/N]: ' "$1" >/dev/tty;read -r answer </dev/tty;[[ "$answer" == y || "$answer" == Y || "$answer" == да ]]; }
  if [[ "$action" == rollback ]]; then
    [[ -f "$current" ]] || fail 'Нет предыдущего обновления для отката'
    confirm 'Вернуть предыдущую версию приложения, сохранив текущую базу?' || exit 0
    restore_application "$current" || fail 'Откат не завершён. Проверьте логи и совместимость базы'
    note 'Предыдущая версия запущена. Текущая база и пользовательские файлы сохранены.';exit 0
  fi
  [[ "$feed" =~ ^[a-z0-9][a-z0-9./:_-]*-update$ ]] || fail 'Некорректный источник пакета обновления'
  version="${version:-stable}"
  [[ "$version" == stable || "$version" =~ ^sha-[a-f0-9]{40}$ ]] || fail 'Версия должна быть stable или sha-ПОЛНЫЙ_SHA'
  note 'Получаем проверенный пакет обновления'
  docker pull --platform linux/amd64 "$feed:$version" || fail 'Не удалось скачать пакет. Нужен доступ к GHCR: docker login ghcr.io с read:packages'
  local controller
  controller="$(docker image inspect --format '{{index .RepoDigests 0}}' "$feed:$version")"
  [[ "$controller" == "$feed@sha256:"* && "${controller##*@sha256:}" =~ ^[a-f0-9]{64}$ ]] || fail 'Registry не вернул точный digest пакета'
  temporary="$(mktemp -d /tmp/noomic-update-bundle.XXXXXX)"
  container="$(docker create --platform linux/amd64 --entrypoint /metadata-only "$controller")"
  docker cp "$container:/release/update.json" "$temporary/update.json"
  docker cp "$container:/release/noomic-deploy.tar.gz" "$temporary/noomic-deploy.tar.gz"
  python3 - "$temporary" "${feed%-update}" <<'PY'
import hashlib,json,re,sys,tarfile
from pathlib import Path
root=Path(sys.argv[1]);prefix=sys.argv[2];path=root/'update.json';archive=root/'noomic-deploy.tar.gz'
if path.is_symlink() or archive.is_symlink():raise SystemExit('Пакет не должен содержать ссылки')
m=json.loads(path.read_text())
if m.get('format')!=1 or m.get('repository')!='RusAbk/math-craft' or m.get('architecture')!='amd64':raise SystemExit('Неподдерживаемый пакет')
commit=m.get('commit','')
if not re.fullmatch('[a-f0-9]{40}',commit) or m.get('version')!='sha-'+commit:raise SystemExit('Неверная версия')
if type(m.get('sequence')) is not int or not 0<m['sequence']<10**12:raise SystemExit('Неверный номер публикации')
for service in ('api','web'):
 if not re.fullmatch(re.escape(prefix+'-'+service+'@sha256:')+'[a-f0-9]{64}',m.get(service+'_ref','')):raise SystemExit('Образы должны быть закреплены по digest и принадлежать этому проекту')
if hashlib.sha256(archive.read_bytes()).hexdigest()!=m.get('sha256'):raise SystemExit('Контрольная сумма архива не совпала')
required={'compose.yaml','docker/Caddyfile','docker/compose.env.example','deployment/deploy.sh','deployment/configure.py','deployment/README.md','update.sh'}
with tarfile.open(archive) as bundle:
 members=bundle.getmembers()
 if {p.name for p in members}!=required or len(members)!=len(required) or any(not p.isfile() or p.size>1024*1024 for p in members):raise SystemExit('Неверное содержимое архива')
 for member in members:
  target=root/'verified'/member.name;target.parent.mkdir(parents=True,exist_ok=True)
  with bundle.extractfile(member) as source:target.write_bytes(source.read())
PY
  local descriptor="$temporary/update.json" tag commit sequence api web installed_sequence
  tag="$(json_get version "$descriptor")";commit="$(json_get commit "$descriptor")";sequence="$(json_get sequence "$descriptor")"
  api="$(json_get api_ref "$descriptor")";web="$(json_get web_ref "$descriptor")"
  [[ "$explicit" == false || "$version" == "$tag" ]] || fail 'Пакет не соответствует запрошенной версии'
  printf 'Установлено: %s\nДоступно:    %s\n' "$(env_get APP_VERSION)" "$tag"
  installed_sequence="$(json_get sequence "$current")"
  if [[ "$explicit" == false && "$installed_sequence" =~ ^[0-9]+$ ]] && (( sequence < installed_sequence )); then note 'Канал указывает на старую публикацию. Установленная версия сохранена.';exit 0;fi
  if [[ "$(json_get controller "$current")" == "$controller" && "$(env_get APP_VERSION)" == "$tag" ]]; then note 'Эта версия уже установлена.';exit 0;fi
  [[ "$action" != check ]] || exit 0
  python3 "$temporary/verified/deployment/configure.py" --env-file "$env_file" --check
  confirm 'Сделать резервную копию и обновить? API будет ненадолго остановлен.' || exit 0
  note '[1/3] Скачиваем оба образа до остановки сервера'
  docker pull "$api";docker pull "$web"
  local reference arch
  arch="$(docker info --format '{{.Architecture}}')";[[ "$arch" != x86_64 ]] || arch=amd64
  [[ "$arch" == amd64 ]] || fail 'Этот выпуск предназначен для linux/amd64'
  for reference in "$api" "$web";do
    [[ "$(docker image inspect --format '{{.Architecture}}' "$reference")" == "$arch" ]] || fail 'Архитектура образа не совпадает с сервером'
    [[ "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$reference")" == "$commit" ]] || fail 'API и сайт должны принадлежать одному коммиту'
  done
  [[ -n "$(compose ps -q api)" && -n "$(compose ps -q web)" ]] || fail 'Нужна работающая установка API и сайта. Для первой установки используйте install.sh'
  operation="$(mktemp -d "$state_dir/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
  [[ ! -f "$current" ]] || cp -- "$current" "$operation/previous.json"
  previous_root="$root"
  python3 - "$descriptor" "$operation/current.json" "$previous_root" "$(env_get APP_VERSION)" "$operation/backup" "$controller" "$installation/current" <<'PY'
import json,sys
from pathlib import Path
m=json.loads(Path(sys.argv[1]).read_text());m.update(previous_root=sys.argv[3],previous_version=sys.argv[4],backup=sys.argv[5],controller=sys.argv[6],had_current=Path(sys.argv[7]).is_symlink())
Path(sys.argv[2]).write_text(json.dumps(m,indent=2)+'\n')
PY
  local release_root="$installation/releases/$commit-${controller##*@sha256:}" stage
  mkdir -p "$installation/releases"
  stage="$(mktemp -d "$installation/releases/.update-XXXXXX")";cp -R "$temporary/verified/." "$stage/"
  python3 - "$stage/deployment/images.override.json" "$api" "$web" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({'services':{'api':{'image':sys.argv[2]},'migrate':{'image':sys.argv[2]},'web':{'image':sys.argv[3]}}})+'\n')
PY
  if [[ -e "$release_root" ]];then
    local file
    while IFS= read -r file;do cmp -s "$stage/$file" "$release_root/$file" || fail 'Каталог выпуска изменён; файлы не перезаписаны';done < <(cd "$temporary/verified" && find . -type f)
    cmp -s "$stage/deployment/images.override.json" "$release_root/deployment/images.override.json" || fail 'Digest выпуска изменён'
    rm -rf -- "$stage"
  else mv -- "$stage" "$release_root";fi
  note '[2/3] Резервная копия, миграции и проверка запуска'
  changed=true
  NOOMIC_CONFIG_LOCK_FD=9 NOOMIC_BACKUP_DIR="$operation/backup" bash "$release_root/deployment/deploy.sh" --local --yes --env-file "$env_file" --version "$tag"
  note '[3/3] Сохраняем успешный выпуск и обновляем клиент'
  atomic_copy "$operation/current.json" "$current"
  atomic_copy "$release_root/update.sh" "$installation/update.sh" 755
  ln -sfn -- "$release_root" "$installation/.current-next";mv -Tf -- "$installation/.current-next" "$installation/current"
  changed=false
  note "Установлена версия ${commit:0:7}. Резервная копия: $operation/backup"
  exit 0
}
noomic_update "$@"
