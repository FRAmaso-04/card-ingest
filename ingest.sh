#!/bin/bash
# ============================================================
# Card Ingest & Organizer
#
# https://github.com/FRAmaso-04/card-ingest  -  licenza MIT
#
# Revisione 2026-10-26:
#  - ignora immagini disco (.dmg), installer e volumi di sistema
#  - galleria leggera: miniature generate solo per le card visibili,
#    video caricati solo quando premi play, streaming a blocchi
#  - pulsante "Sfoglia..." per scegliere QUALSIASI cartella di
#    destinazione + opzioni sottocartella data / separazione per tipo
#  - indice SSD in cache (non riscansiona tutto l'SSD a ogni scheda)
#  - se l'SSD non e' collegato la scheda viene rimandata, non fallisce
#  - selezione per ID univoco (file omonimi in cartelle diverse)
#  - log senza duplicati e con rotazione
#
# Rileva schede/card video e foto appena collegate, mostra una
# galleria con miniature nel browser (raggruppata per giornata,
# con un campo "progetto" per gruppo cosi' puoi smistare giorni
# diversi in progetti/sottocartelle diversi, scegliendo tra
# quelli gia' esistenti sull'SSD o scrivendone uno nuovo), e
# copia SOLO i file scelti, organizzandoli in:
#   <SSD>/<Progetto scelto per quella data>/<Data ripresa>/VIDEO/          video
#   <SSD>/<Progetto scelto per quella data>/<Data ripresa>/JPG/            foto jpg/heic/png
#   <SSD>/<Progetto scelto per quella data>/<Data ripresa>/RAW/            foto raw
#
# Appena premi "Copia selezionati" la pagina del browser viene
# CHIUSA automaticamente e la copia prosegue in background alla
# massima velocita' (niente server web attivo, niente polling,
# niente aggiornamenti di avanzamento da scrivere). A fine copia:
# suono + finestra di riepilogo.
# Per fermare una copia in corso c'e' SOLO il doppio click su
# "STOP Trasferimento.command" sul Desktop (creato in automatico).
#
# I file deselezionati nella galleria NON vengono cancellati
# dalla scheda: restano li', ma vengono aggiunti a una blacklist
# persistente (~/.card_ingest/blacklist.txt) cosi' non vengono
# piu' riproposti nei prossimi import, anche ricollegando la
# stessa scheda. Per "ripescare" un file basta aprire
# blacklist.txt con un editor di testo e cancellare la riga.
#
# I nomi progetto usati vengono ricordati in
# ~/.card_ingest/recent_projects.txt e riproposti come
# suggerimenti nella galleria (oltre alle cartelle gia'
# esistenti sull'SSD).
#
# La cartella dei progetti (SSD_ROOT) puo' essere impostata senza
# toccare questo file: l'installer scrive ~/.card_ingest/config.sh
# e questo script la legge a ogni avvio.
#
# La galleria richiede python3 e qlmanage (entrambi gia' su
# macOS). Se mancano, si torna a un dialogo nativo piu' semplice
# (un solo progetto per l'intera scheda, niente miniature, niente
# smistamento per data).
# ============================================================

set -uo pipefail

### CONFIGURAZIONE — valori di default, sovrascrivibili da config.sh ###
SSD_ROOT=""   # impostato da install.sh in ~/.card_ingest/config.sh
VIDEO_EXTENSIONS=(mp4 mov mxf braw r3d avi mts m2ts)
JPG_EXTENSIONS=(jpg jpeg heic png tif tiff)
RAW_EXTENSIONS=(cr2 cr3 nef arw dng raf orf rw2 raw)
# Alcune videocamere (es. Canon Cinema EOS) registrano per ogni clip
# anche un clip "proxy" a bassa risoluzione, con lo stesso nome del
# clip principale + suffisso S0N prima dell'estensione (es. C9666.MP4
# + C9666S03.MP4: quest'ultimo e' un file di appoggio per il montaggio
# offline, molto piu' leggero, NON un video separato). Con 1 questi
# proxy non vengono proposti/copiati; metti 0 in config.sh per
# copiarli comunque.
SKIP_VIDEO_PROXIES=1
STATE_DIR="$HOME/.card_ingest"
KNOWN_VOLUMES_FILE="$STATE_DIR/known_volumes.txt"
BLACKLIST_FILE="$STATE_DIR/blacklist.txt"
RECENT_PROJECTS_FILE="$STATE_DIR/recent_projects.txt"
LOG_FILE="$STATE_DIR/ingest.log"
LOCK_DIR="$STATE_DIR/lock"
# UNICO modo per fermare una copia in corso: creare questo file, con un
# doppio click sullo script sul Desktop o da terminale con "touch".
# La copia si ferma al primo file utile. (Il pulsante di stop nel
# browser e' stato rimosso: la pagina si chiude appena parte la copia.)
STOP_SIGNAL_FILE="$STATE_DIR/stop_now"
STOP_HELPER_SCRIPT="$HOME/Desktop/STOP Trasferimento.command"
# Tentativi se la scheda sembra vuota appena montata: veloce all'inizio
# (il caso comune), via via piu' paziente (~22s di margine totale)
MOUNT_RETRY_DELAYS=(0.5 0.5 0.5 1 1 1 2 2 2 2 2 2 2 2 2)
SYSTEM_VOLUMES=("Macintosh HD" "Macintosh HD - Data")   # volumi da ignorare sempre
GALLERY_PORT=8734          # porta locale per la galleria di anteprima
GALLERY_THUMB_SIZE=320     # dimensione miniature in pixel
GALLERY_TIMEOUT_SECS=1200  # quanto aspettare la tua scelta nel browser (20 min)
RECAP_SOUND="/System/Library/Sounds/Glass.aiff"
### FINE CONFIGURAZIONE ###

# Config esterna (scritta dall'installer): puo' ridefinire SSD_ROOT ecc.
CONFIG_FILE="$STATE_DIR/config.sh"
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

if [ -z "${SSD_ROOT:-}" ]; then
  echo "Card Ingest: SSD_ROOT non configurato, esegui install.sh" >&2
  exit 0
fi

# Indice in cache dei file gia' presenti sull'SSD (basename|size):
# ricostruito al massimo ogni DEST_INDEX_MAX_AGE secondi o se cambia
# SSD_ROOT, e aggiornato a ogni file copiato. Per forzarne la
# ricostruzione basta cancellare dest_index.meta.
DEST_INDEX_CACHE="$STATE_DIR/dest_index.txt"
DEST_INDEX_META="$STATE_DIR/dest_index.meta"
DEST_INDEX_MAX_AGE=${DEST_INDEX_MAX_AGE:-21600}   # 6 ore
# Schede inserite mentre l'SSD di destinazione non era collegato:
# vengono riproposte appena l'SSD compare.
PENDING_FILE="$STATE_DIR/pending_volumes.txt"
# Volume che contiene SSD_ROOT (es. "/Volumes/MioSSD"), vuoto se
# SSD_ROOT non sta sotto /Volumes
SSD_VOL=$(printf '%s' "$SSD_ROOT" | awk -F/ '$2=="Volumes" && $3!="" {print "/Volumes/" $3}')

mkdir -p "$STATE_DIR"
touch "$KNOWN_VOLUMES_FILE" "$BLACKLIST_FILE" "$RECENT_PROJECTS_FILE" "$PENDING_FILE"

# --- Crea lo script "STOP Trasferimento" sul Desktop (doppio click =
#     ferma la copia in corso). Viene scritto solo quando parte una
#     copia e solo se manca/e' diverso: prima veniva riscritto a ogni
#     avvio dello script, cioe' ogni 45 secondi. ---
ensure_stop_helper() {
  if [ -x "$STOP_HELPER_SCRIPT" ] && grep -qF "$STOP_SIGNAL_FILE" "$STOP_HELPER_SCRIPT" 2>/dev/null; then
    return 0
  fi
  {
    cat > "$STOP_HELPER_SCRIPT" << STOPEOF
#!/bin/bash
touch "$STOP_SIGNAL_FILE"
osascript -e 'display notification "Si fermera al file in corso." with title "Card Ingest: stop richiesto"' >/dev/null 2>&1
STOPEOF
    chmod +x "$STOP_HELPER_SCRIPT"
  } 2>/dev/null || true
}

# --- Costruisce liste di argomenti "-iname *.ext -o -iname *.ext ..." per find.
#     Esclude sempre i file nascosti e i file AppleDouble ("._NOME.JPG",
#     metadati da 4KB che macOS crea sulle schede formattate exFAT/FAT:
#     matchano *.jpg ma non sono foto) e tutto cio' che sta dentro
#     cartelle nascoste (.Trashes, .Spotlight-V100, ...). ---
build_find_args() {
  local __outvar="$1"; shift
  local args=( "(" -iname "*.$1" )
  shift
  for ext in "$@"; do
    args+=( -o -iname "*.${ext}" )
  done
  args+=( ")" "!" -name ".*" "!" -path "*/.*/*" "!" -path "*.app/*" "!" -path "*.bundle/*" "!" -path "*.framework/*" )
  eval "$__outvar=(\"\${args[@]}\")"
}

build_find_args VIDEO_FIND_ARGS "${VIDEO_EXTENSIONS[@]}"
build_find_args JPG_FIND_ARGS   "${JPG_EXTENSIONS[@]}"
build_find_args RAW_FIND_ARGS   "${RAW_EXTENSIONS[@]}"
build_find_args ALL_FIND_ARGS   "${VIDEO_EXTENSIONS[@]}" "${JPG_EXTENSIONS[@]}" "${RAW_EXTENSIONS[@]}"

# Difesa aggiuntiva: se sulla scheda i JPEG di anteprima dei video stanno
# in una cartella con "thumbnail/thumbnails/thumbs" nel nome, escludili a
# priori (oltre al filtro per nome file fatto piu' sotto in
# strip_video_thumbnail_jpgs, che copre anche il caso in cui stiano nella
# stessa cartella dei clip).
JPG_FIND_ARGS+=( "!" -ipath "*/thumbnail*" "!" -ipath "*/thumbnails*" "!" -ipath "*/thumbs*" )

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S')  $1" >> "$LOG_FILE"
}

notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1
}

html_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

as_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Ricorda un progetto come "usato di recente" (piu' recente = primo)
remember_project() {
  local proj="$1"
  local tmp
  tmp=$(mktemp)
  printf '%s\n' "$proj" > "$tmp"
  grep -vxF "$proj" "$RECENT_PROJECTS_FILE" 2>/dev/null | head -n 19 >> "$tmp"
  mv "$tmp" "$RECENT_PROJECTS_FILE"
}

# Mostra il riepilogo finale: suono + finestra che resta finche' non la chiudi
show_recap() {
  local title="$1"
  local body="$2"
  [ -f "$RECAP_SOUND" ] && afplay "$RECAP_SOUND" >/dev/null 2>&1 &
  osascript -e "display dialog \"$(as_escape "$body")\" with title \"$(as_escape "$title")\" buttons {\"OK\"} default button \"OK\" with icon note" >/dev/null 2>&1 &
}

# --- Chiude la scheda della galleria nel browser (Safari + browser
#     Chromium piu' comuni). Agisce solo sui browser GIA' aperti:
#     il controllo pgrep evita di lanciare app chiuse. Errori ignorati. ---
close_gallery_tab() {
  local frag="127.0.0.1:${GALLERY_PORT}"
  if pgrep -xq "Safari"; then
    osascript -e "tell application \"Safari\" to close (every tab of every window whose URL contains \"$frag\")" >/dev/null 2>&1
  fi
  local APP
  for APP in "Google Chrome" "Brave Browser" "Microsoft Edge" "Arc"; do
    if pgrep -xq "$APP"; then
      osascript \
        -e "tell application \"$APP\"" \
        -e "repeat with w in windows" \
        -e "repeat with t in (tabs of w)" \
        -e "if URL of t contains \"$frag\" then close t" \
        -e "end repeat" \
        -e "end repeat" \
        -e "end tell" >/dev/null 2>&1
    fi
  done
}

# --- Indice di cio' che c'e' gia' su una cartella di destinazione:
#     UNA sola invocazione di stat per blocchi di file (exec +) invece
#     di una per file: molto piu' veloce su SSD pieni.
#     Output: una riga "basename|size" per file. ---
build_dest_index() {
  local dir="$1" out="$2"
  find "$dir" -type f -exec stat -f '%z|%N' {} + 2>/dev/null |
    awk '{ i=index($0,"|"); s=substr($0,1,i-1); p=substr($0,i+1); sub(".*/","",p); print p "|" s }' > "$out"
}

# --- Restituisce l'indice (cache) dei file gia' presenti sull'SSD ---
get_dest_index() {
  local out="$1" now meta_root="" built=0
  now=$(date +%s)
  if [ -f "$DEST_INDEX_CACHE" ] && [ -f "$DEST_INDEX_META" ]; then
    IFS='|' read -r meta_root built < "$DEST_INDEX_META" || true
  fi
  case "$built" in ''|*[!0-9]*) built=0 ;; esac
  if [ "$meta_root" != "$SSD_ROOT" ] || [ $((now - built)) -gt "$DEST_INDEX_MAX_AGE" ]; then
    build_dest_index "$SSD_ROOT" "$DEST_INDEX_CACHE.tmp"
    mv -f "$DEST_INDEX_CACHE.tmp" "$DEST_INDEX_CACHE"
    printf '%s|%s\n' "$SSD_ROOT" "$now" > "$DEST_INDEX_META"
    log "Indice dei file gia' presenti sull'SSD ricostruito ($(wc -l < "$DEST_INDEX_CACHE" | tr -d ' ') file)"
  fi
  cp "$DEST_INDEX_CACHE" "$out"
}

# --- Vero se il volume NON e' una scheda/memoria da importare:
#     immagini disco (.dmg dei programmi scaricati), installer,
#     volumi di sistema/aggiornamento. ---
is_not_a_card() {
  local vol="$1" vp="$2"
  case "$vol" in
    msu-target-*|Recovery|Preboot|VM|Update|"Macintosh HD"*) return 0 ;;
  esac
  # Montato da un'immagine disco?
  if hdiutil info 2>/dev/null | awk -F'\t' -v p="$vp" '{m=$NF; sub(/[ \t]+$/,"",m); if (m==p) f=1} END{exit !f}'; then
    return 0
  fi
  if diskutil info "$vp" 2>/dev/null | grep -Eq '^ *Protocol: +Disk Image'; then
    return 0
  fi
  # Installer di un programma (app o pacchetto in radice)?
  if [ -n "$(find "$vp" -maxdepth 1 \( -iname '*.app' -o -iname '*.pkg' -o -iname '*.mpkg' \) -print -quit 2>/dev/null)" ]; then
    return 0
  fi
  return 1
}

# --- Tiene i log sotto controllo: se superano max byte ne conserva
#     solo l'ultimo quarto (riscrivendo lo stesso file, cosi' launchd
#     continua a scriverci). ---
rotate_log() {
  local f="$1" max="$2" sz
  [ -f "$f" ] || return 0
  sz=$(stat -f%z "$f" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$max" ]; then
    tail -c $((max / 4)) "$f" > "$f.tmp" 2>/dev/null && cat "$f.tmp" > "$f"
    rm -f "$f.tmp"
  fi
}

# --- Toglie dalla lista i JPEG che sono in realta' le miniature dei
#     video: alcune videocamere (es. Canon Cinema EOS) ne creano una per
#     ogni clip, con lo stesso nome del video + suffisso T0N prima
#     dell'estensione (es. C9666.MP4 -> C9666T01.JPG), spesso nella
#     stessa cartella del clip (a volte in una sottocartella dedicata,
#     gia' esclusa sopra da JPG_FIND_ARGS se il nome contiene "thumb").
#     Qui il confronto e' per nome file: se esiste un video con lo
#     stesso nome base, il JPEG e' la sua miniatura e non una foto vera,
#     quindi si scarta sempre (non e' disattivabile: non e' mai utile). ---
strip_video_thumbnail_jpgs() {
  local media_list="$1" out="$2"
  local vid_bases
  vid_bases=$(mktemp)
  awk -F'|' '$1=="VIDEO"{n=$2; sub(/.*\//,"",n); sub(/\.[^.]*$/,"",n); print tolower(n)}' "$media_list" | sort -u > "$vid_bases"
  awk -F'|' -v basefile="$vid_bases" '
    BEGIN { while ((getline line < basefile) > 0) vid[line]=1 }
    {
      if ($1=="JPG") {
        n=$2; sub(/.*\//,"",n); sub(/\.[^.]*$/,"",n); ln=tolower(n)
        if (ln ~ /t[0-9][0-9]$/) {
          base=ln; sub(/t[0-9][0-9]$/,"",base)
          if (base in vid) next
        }
      }
      print
    }
  ' "$media_list" > "$out"
  rm -f "$vid_bases"
}

# --- Toglie dalla lista i clip video "proxy" a bassa risoluzione che
#     alcune videocamere registrano in automatico accanto al clip
#     principale: stesso nome + suffisso S0N prima dell'estensione
#     (es. C9666.MP4 + C9666S03.MP4, quest'ultimo molto piu' leggero).
#     Non sono un secondo video: sono un file di appoggio per il
#     montaggio offline. Disattivabile con SKIP_VIDEO_PROXIES=0 in
#     config.sh, se invece li si vuole tenere. ---
strip_video_proxies() {
  local media_list="$1" out="$2"
  if [ "${SKIP_VIDEO_PROXIES:-1}" != "1" ]; then
    cp "$media_list" "$out"
    return
  fi
  local vid_bases
  vid_bases=$(mktemp)
  awk -F'|' '$1=="VIDEO"{n=$2; sub(/.*\//,"",n); sub(/\.[^.]*$/,"",n); print tolower(n)}' "$media_list" | sort -u > "$vid_bases"
  awk -F'|' -v basefile="$vid_bases" '
    BEGIN { while ((getline line < basefile) > 0) vid[line]=1 }
    {
      if ($1=="VIDEO") {
        n=$2; sub(/.*\//,"",n); sub(/\.[^.]*$/,"",n); ln=tolower(n)
        if (ln ~ /s0[0-9]$/) {
          base=ln; sub(/s0[0-9]$/,"",base)
          if (base in vid) next
        }
      }
      print
    }
  ' "$media_list" > "$out"
  rm -f "$vid_bases"
}

# --- Applica in sequenza i due filtri qui sopra a un MEDIA_LIST ---
clean_media_list() {
  local media_list="$1"
  local tmp1 tmp2
  tmp1=$(mktemp)
  strip_video_thumbnail_jpgs "$media_list" "$tmp1"
  tmp2=$(mktemp)
  strip_video_proxies "$tmp1" "$tmp2"
  mv "$tmp2" "$media_list"
  rm -f "$tmp1"
}

# --- Filtro dei candidati in una sola passata ---------------------------
# Legge MEDIA_LIST (righe "TYPE|/path/file"), fa UNA stat per file (data
# di ripresa + dimensione insieme, invece di due chiamate separate) e poi
# un'unica passata awk contro indice SSD e blacklist caricati in memoria:
# niente piu' un grep per ogni file, che con blacklist lunghe e schede
# piene diventava quadratico e lento.
# Output CANDIDATE_LIST: righe "DATE|TYPE|SRC|basename|size"
#   (gli ultimi due campi letti insieme formano la KEY "basename|size").
# In counts_out scrive "gia_presenti|in_blacklist".
filter_candidates() {
  local media_list="$1" index_file="$2" out_list="$3" counts_out="$4"
  local raw TYPE SRC META
  raw=$(mktemp)
  while IFS='|' read -r TYPE SRC; do
    [ -z "$SRC" ] && continue
    META=$(stat -f "%Sm|%z" -t "%Y-%m-%d" "$SRC" 2>/dev/null) || continue
    printf '%s|%s|%s|%s|%s\n' "${META%%|*}" "$TYPE" "$SRC" "$(basename "$SRC")" "${META##*|}"
  done < "$media_list" > "$raw"
  awk -F'|' -v countsfile="$counts_out" '
    FILENAME==ARGV[1] { idx[$0]=1; next }
    FILENAME==ARGV[2] { bl[$0]=1; next }
    {
      key=$(NF-1) "|" $NF
      if (key in idx) { skip++; next }
      if (key in bl)  { black++; next }
      print
    }
    END { print (skip+0) "|" (black+0) > countsfile }
  ' "$index_file" "$BLACKLIST_FILE" "$raw" > "$out_list"
  rm -f "$raw"
}

# --- Lock con auto-riparazione: se il lock appartiene a un processo
#     morto (script ucciso, crash, riavvio del Mac: il trap EXIT in quei
#     casi non scatta e il lock resterebbe li' PER SEMPRE, bloccando
#     ogni import futuro), lo si rimuove e si continua. ---
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  OLD_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    exit 0   # c'e' davvero un'altra esecuzione in corso
  fi
  log "Lock orfano trovato (processo ${OLD_PID:-sconosciuto} non piu' attivo): lo rimuovo e continuo"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCK_DIR/pid"
MONITOR_PID=""
trap 'rm -rf "$LOCK_DIR" 2>/dev/null; [ -n "$MONITOR_PID" ] && kill "$MONITOR_PID" 2>/dev/null' EXIT

# --- Monitor dei volumi durante il lavoro ---------------------------
# Mentre questo giro e' occupato (galleria aperta, copia in corso),
# gli eventi di launchd per altre schede/chiavette arrivano mentre il
# lock e' preso e vanno persi. Se una chiavetta viene TOLTA e poi
# RIMESSA in quel lasso di tempo, a fine giro /Volumes sembrerebbe
# identico a prima e la chiavetta non verrebbe piu' rilevata.
# Questo monitor controlla ogni 2 secondi: appena un volume sparisce lo
# toglie da known_volumes.txt, cosi' al reinserimento risulta "nuovo"
# e il controllo finale riavvia lo script per proporlo.
start_volume_monitor() {
  (
    while kill -0 "$1" 2>/dev/null; do
      sleep 2
      while IFS= read -r KV; do
        [ -z "$KV" ] && continue
        if [ ! -e "/Volumes/$KV" ]; then
          grep -vxF "$KV" "$KNOWN_VOLUMES_FILE" > "$KNOWN_VOLUMES_FILE.mon" 2>/dev/null
          mv -f "$KNOWN_VOLUMES_FILE.mon" "$KNOWN_VOLUMES_FILE"
          log "Volume '$KV' scollegato durante il lavoro: sara' riproposto se lo ricolleghi"
        fi
      done < "$KNOWN_VOLUMES_FILE"
    done
  ) >/dev/null 2>&1 &
  MONITOR_PID=$!
}
# Pulisce un eventuale segnale di stop rimasto da un import precedente,
# cosi' non blocca subito questo nuovo giro
rm -f "$STOP_SIGNAL_FILE"

rotate_log "$LOG_FILE" 2000000
rotate_log "$STATE_DIR/launchd.out.log" 500000
rotate_log "$STATE_DIR/launchd.err.log" 500000

USE_GALLERY=0
if command -v python3 >/dev/null 2>&1 && command -v qlmanage >/dev/null 2>&1; then
  USE_GALLERY=1
fi

# --- 1. Trova i volumi nuovi rispetto all'ultima scansione ---
CURRENT_VOLUMES=$(ls -1 /Volumes 2>/dev/null)
NEW_VOLUMES=()
while IFS= read -r vol; do
  [ -z "$vol" ] && continue
  if ! grep -qxF "$vol" "$KNOWN_VOLUMES_FILE"; then
    NEW_VOLUMES+=("$vol")
  fi
done <<< "$CURRENT_VOLUMES"

# Schede rimandate perche' l'SSD non era collegato: se ora c'e',
# riproponile (se sono ancora inserite)
if [ -s "$PENDING_FILE" ] && { [ -z "$SSD_VOL" ] || [ -d "$SSD_VOL" ]; }; then
  while IFS= read -r PV; do
    [ -z "$PV" ] && continue
    [ -d "/Volumes/$PV" ] || continue
    ALREADY=0
    for NV in ${NEW_VOLUMES[@]+"${NEW_VOLUMES[@]}"}; do
      [ "$NV" = "$PV" ] && ALREADY=1
    done
    [ "$ALREADY" -eq 0 ] && NEW_VOLUMES+=("$PV")
  done < "$PENDING_FILE"
  : > "$PENDING_FILE"
fi

echo "$CURRENT_VOLUMES" > "$KNOWN_VOLUMES_FILE"

[ ${#NEW_VOLUMES[@]} -eq 0 ] && exit 0

start_volume_monitor $$

for VOL in "${NEW_VOLUMES[@]}"; do
  VOL_PATH="/Volumes/$VOL"

  case "$SSD_ROOT" in
    "$VOL_PATH"|"$VOL_PATH"/*) continue ;;
  esac

  IS_SYSTEM_VOL=0
  for SYSVOL in "${SYSTEM_VOLUMES[@]}"; do
    [ "$VOL" = "$SYSVOL" ] && IS_SYSTEM_VOL=1
  done
  [ "$IS_SYSTEM_VOL" -eq 1 ] && continue

  if is_not_a_card "$VOL" "$VOL_PATH"; then
    log "Volume '$VOL' ignorato (immagine disco, installer o volume di sistema)"
    continue
  fi

  # Riprova piu' volte: appena montata, la scheda potrebbe non
  # essere ancora completamente leggibile. Dato che il lock lascia
  # processare la scheda a UNA sola esecuzione, qui conviene avere
  # pazienza piuttosto che arrendersi troppo presto.
  FIRST_MEDIA=""
  TRIES=0
  for DELAY in "" "${MOUNT_RETRY_DELAYS[@]}"; do
    [ -n "$DELAY" ] && sleep "$DELAY"
    [ -d "$VOL_PATH" ] || break
    FIRST_MEDIA=$(find "$VOL_PATH" -maxdepth 6 -type f "${ALL_FIND_ARGS[@]}" -print -quit 2>/dev/null)
    [ -n "$FIRST_MEDIA" ] && break
    TRIES=$((TRIES + 1))
    # Il volume e' gia' leggibile (contiene qualcosa) ma non ha media:
    # non e' una scheda della fotocamera, inutile insistere ~20 secondi.
    if [ "$TRIES" -ge 3 ] && [ -n "$(ls "$VOL_PATH" 2>/dev/null | head -1)" ]; then
      break
    fi
  done

  if [ -z "$FIRST_MEDIA" ]; then
    log "Volume '$VOL' ignorato (nessun video/foto trovato dopo $TRIES tentativi)"
    continue
  fi

  log "Scheda rilevata: $VOL"

  if [ -n "$SSD_VOL" ] && [ ! -d "$SSD_VOL" ]; then
    log "SSD di destinazione non collegato ($SSD_VOL): import di $VOL rimandato"
    notify "Card Ingest" "Collega l'SSD ${SSD_VOL#/Volumes/}: la scheda $VOL verra' proposta appena lo colleghi"
    printf '%s\n' "$VOL" >> "$PENDING_FILE"
    continue
  fi
  if ! mkdir -p "$SSD_ROOT" 2>/dev/null; then
    log "ERRORE: non riesco a creare $SSD_ROOT, import di $VOL annullato"
    notify "Card Ingest" "Impossibile scrivere su $SSD_ROOT"
    continue
  fi

  TO_COPY_LIST=""
  DESELECTED_COUNT=0
  ABORT=0
  STOPPED_MIDWAY=0
  CARD_REMOVED=0

  if [ "$USE_GALLERY" -eq 1 ]; then
    # ==========================================================
    # --- Percorso principale: galleria nel browser, con
    #     smistamento per data su progetti/cartelle a scelta ---
    # ==========================================================

    # --- Indicizza TUTTO cio' che e' gia' presente sull'SSD, in
    #     qualunque progetto (evita di riproporre un file gia'
    #     importato altrove) ---
    INDEX_FILE=$(mktemp)
    get_dest_index "$INDEX_FILE"

    # --- Elenca tutti i media sulla scheda, tag per tipo ---
    MEDIA_LIST=$(mktemp)
    find "$VOL_PATH" -type f "${VIDEO_FIND_ARGS[@]}" 2>/dev/null | sed 's/^/VIDEO|/' >  "$MEDIA_LIST"
    find "$VOL_PATH" -type f "${JPG_FIND_ARGS[@]}"   2>/dev/null | sed 's/^/JPG|/'   >> "$MEDIA_LIST"
    find "$VOL_PATH" -type f "${RAW_FIND_ARGS[@]}"   2>/dev/null | sed 's/^/RAW|/'   >> "$MEDIA_LIST"

    # Toglie le miniature JPEG dei video e (se abilitato) i clip proxy
    clean_media_list "$MEDIA_LIST"

    TOTAL=$(wc -l < "$MEDIA_LIST" | tr -d ' ')

    # --- Filtra: fuori chi e' gia' sull'SSD, fuori chi e' in
    #     blacklist. Calcola anche la data ripresa (una passata sola) ---
    CANDIDATE_LIST=$(mktemp)
    COUNTS_FILE=$(mktemp)
    filter_candidates "$MEDIA_LIST" "$INDEX_FILE" "$CANDIDATE_LIST" "$COUNTS_FILE"
    SKIP=0
    BLACKLISTED_COUNT=0
    IFS='|' read -r SKIP BLACKLISTED_COUNT < "$COUNTS_FILE" || true
    rm -f "$COUNTS_FILE"

    CANDIDATES=$(wc -l < "$CANDIDATE_LIST" | tr -d ' ')

    if [ "$CANDIDATES" -eq 0 ]; then
      log "Nulla da proporre su $VOL - $TOTAL file, $SKIP gia' presenti, $BLACKLISTED_COUNT in blacklist"
      notify "Card Ingest" "Nessun file nuovo su '$VOL' (gia' importato o in blacklist)"
      rm -f "$INDEX_FILE" "$MEDIA_LIST" "$CANDIDATE_LIST"
      continue
    fi

    # --- Elenco progetti conosciuti: usati di recente + cartelle
    #     gia' esistenti sull'SSD (deduplicato, i piu' recenti prima).
    #     I "recenti" vengono prima verificati contro le cartelle che
    #     esistono DAVVERO sull'SSD in questo momento: se una cartella
    #     e' stata cancellata a mano, sparisce dal menu (e viene tolta
    #     anche dal file persistente, cosi' non ricompare piu'). ---
    EXISTING_PROJECTS_FILE=$(mktemp)
    find "$SSD_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r d; do
      basename "$d"
    done | sort > "$EXISTING_PROJECTS_FILE"

    FILTERED_RECENT_FILE=$(mktemp)
    while IFS= read -r P; do
      [ -z "$P" ] && continue
      [ -d "$SSD_ROOT/$P" ] && echo "$P" >> "$FILTERED_RECENT_FILE"
    done < "$RECENT_PROJECTS_FILE"
    cp "$FILTERED_RECENT_FILE" "$RECENT_PROJECTS_FILE" 2>/dev/null

    KNOWN_PROJECTS_FILE=$(mktemp)
    cat "$FILTERED_RECENT_FILE" "$EXISTING_PROJECTS_FILE" > "$KNOWN_PROJECTS_FILE"
    awk '!seen[$0]++' "$KNOWN_PROJECTS_FILE" > "${KNOWN_PROJECTS_FILE}.dedup"
    mv "${KNOWN_PROJECTS_FILE}.dedup" "$KNOWN_PROJECTS_FILE"
    rm -f "$EXISTING_PROJECTS_FILE" "$FILTERED_RECENT_FILE"

    # Opzioni <option> riutilizzate sia nel menu "applica a tutte" che
    # in ogni menu per giornata. Il primo della lista e' quello usato
    # piu' di recente, cosi' diventa il default automatico.
    PROJECT_OPTIONS_HTML=""
    HAS_KNOWN_PROJECTS=0
    while IFS= read -r P; do
      [ -z "$P" ] && continue
      HAS_KNOWN_PROJECTS=1
      P_HTML=$(html_escape "$P")
      PROJECT_OPTIONS_HTML="${PROJECT_OPTIONS_HTML}<option value=\"${P_HTML}\">${P_HTML}</option>"
    done < "$KNOWN_PROJECTS_FILE"

    DATES_FILE=$(mktemp)
    cut -d'|' -f1 "$CANDIDATE_LIST" | sort -u > "$DATES_FILE"

    GALLERY_DIR=$(mktemp -d)
    mkdir -p "$GALLERY_DIR/thumbs" "$GALLERY_DIR/media"

    # Ogni candidato riceve un ID univoco (numero di riga): due file con
    # lo stesso nome in cartelle diverse della scheda restano distinti.
    # Le miniature NON vengono piu' generate tutte insieme: le crea il
    # server locale su richiesta, solo per le card che il browser
    # mostra davvero (loading="lazy"), max 2 alla volta, a bassa priorita'.
    NUMBERED_LIST=$(mktemp)
    CID=0
    while IFS='|' read -r DATE TYPE SRC KEY; do
      CID=$((CID + 1))
      [ -z "$SRC" ] && continue
      BN=$(basename "$SRC")
      ln -sf "$SRC" "$GALLERY_DIR/media/${CID}__${BN}" 2>/dev/null
      printf '%s|%s|%s|%s\n' "$CID" "$DATE" "$TYPE" "$SRC" >> "$NUMBERED_LIST"
    done < "$CANDIDATE_LIST"

    {
      cat << 'HTML_HEAD'
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<title>Card Ingest</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; background: #f5f5f2; color: #1a1a1a; }
  header { position: sticky; top: 0; background: #fff; border-bottom: 1px solid #ddd; padding: 12px 20px; display: flex; align-items: center; gap: 10px; z-index: 10; flex-wrap: wrap; }
  header h1 { font-size: 15px; font-weight: 600; margin: 0; flex: 1; min-width: 160px; }
  header button { padding: 8px 14px; border-radius: 6px; border: 1px solid #ccc; background: #fff; cursor: pointer; font-size: 13px; }
  header button.primary { background: #0a7cff; color: #fff; border-color: #0a7cff; font-weight: 600; }
  header button.danger { color: #a32d2d; border-color: #e0b3b3; }
  .date-section { padding: 16px 20px 4px; }
  .date-header { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-bottom: 10px; }
  .date-header h2 { font-size: 14px; font-weight: 600; margin: 0; }
  .date-header label { font-size: 12px; color: #666; }
  .date-header select.project-select, .date-header input.project-new-input { font-size: 13px; padding: 6px 10px; border-radius: 6px; border: 1px solid #ccc; min-width: 200px; }
  #apply-all-select { font-size: 13px; padding: 8px 10px; border-radius: 6px; border: 1px solid #ccc; }
  button.mini { padding: 5px 10px; font-size: 12px; border-radius: 6px; border: 1px solid #ccc; background: #fff; cursor: pointer; }
  .date-section.collapsed .grid { display: none; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: 14px; padding-bottom: 10px; }
  .card { background: #fff; border-radius: 8px; overflow: hidden; border: 1px solid #e0e0e0; }
  .card.unchecked { opacity: 0.35; }
  .thumb-wrap { position: relative; width: 100%; aspect-ratio: 4/3; background: #222; display: flex; align-items: center; justify-content: center; }
  .thumb-wrap img, .thumb-wrap video { width: 100%; height: 100%; object-fit: cover; display: block; }
  .placeholder { font-size: 11px; color: #ccc; text-align: center; padding: 8px; word-break: break-all; }
  .info { padding: 8px 10px; display: flex; align-items: center; gap: 8px; }
  .info input[type=checkbox] { width: 17px; height: 17px; flex-shrink: 0; }
  .name { font-size: 11px; word-break: break-all; flex: 1; }
  .badge { font-size: 10px; padding: 2px 6px; border-radius: 4px; background: #eee; color: #555; flex-shrink: 0; }
  .badge.VIDEO { background: #ffe4d6; color: #a34a1f; }
  .badge.JPG { background: #dcefff; color: #1c5a99; }
  .badge.RAW { background: #e6dcff; color: #5a3c99; }
  .video-thumb { cursor: pointer; }
  .play { position: absolute; font-size: 30px; color: #fff; text-shadow: 0 1px 8px rgba(0,0,0,.7); pointer-events: none; }
  .dest-path { font-size: 12px; color: #1a7f37; max-width: 420px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .dest-path a { color: #a32d2d; text-decoration: none; margin-left: 4px; }
  header label.opt { font-size: 12px; color: #444; display: flex; align-items: center; gap: 4px; }
  select:disabled { opacity: .4; }
  footer { position: sticky; bottom: 0; background: #fff; border-top: 1px solid #ddd; padding: 12px 20px; text-align: center; font-size: 13px; color: #555; }
</style>
<script>
// Le miniature vengono create dal server locale su richiesta, solo per
// le card visibili: se una non riesce si ritenta un paio di volte e poi
// si mostra il nome del file.
function handleImgError(img) {
  var tries = (parseInt(img.dataset.tries || '0', 10)) + 1;
  img.dataset.tries = tries;
  if (tries > 2) {
    var ph = document.createElement('div');
    ph.className = 'placeholder';
    ph.textContent = img.dataset.label || '';
    img.replaceWith(ph);
    return;
  }
  setTimeout(function() {
    img.src = '/thumbs/' + encodeURIComponent(img.dataset.media) + '.png?t=' + Date.now();
  }, 1500);
}
// Il video viene caricato dalla scheda SOLO quando ci clicchi sopra
function playVideo(wrap) {
  if (wrap.dataset.playing) return;
  wrap.dataset.playing = '1';
  var v = document.createElement('video');
  v.controls = true; v.autoplay = true; v.preload = 'none';
  v.src = wrap.dataset.src;
  wrap.innerHTML = '';
  wrap.appendChild(v);
}
</script>
</head>
<body>
<header>
  <h1 id="counter">selezionati</h1>
HTML_HEAD

      echo "  <select id=\"apply-all-select\" onchange=\"applyToAll(this.value)\"><option value=\"\">Applica progetto a tutte le giornate…</option>${PROJECT_OPTIONS_HTML}</select>"

      cat << 'HTML_HEAD2'
  <label class="opt" title="Crea una sottocartella AAAA-MM-GG per ogni giornata"><input type="checkbox" id="opt-datesub" checked> Sottocartella data</label>
  <label class="opt" title="Separa in VIDEO / JPG / RAW"><input type="checkbox" id="opt-typesub" checked> Separa per tipo</label>
  <button onclick="pickFolder(null)">Sfoglia… (tutte le giornate)</button>
  <button onclick="selectAll(true)">Seleziona tutto</button>
  <button onclick="selectAll(false)">Deseleziona tutto</button>
  <button class="danger" onclick="submitSelection('cancel')">Annulla import</button>
  <button class="primary" onclick="submitSelection('confirm')">Copia selezionati</button>
</header>
HTML_HEAD2

      while IFS= read -r DATE; do
        [ -z "$DATE" ] && continue
        DATE_HTML=$(html_escape "$DATE")
        COUNT_FOR_DATE=$(grep -c "^${DATE}|" "$CANDIDATE_LIST")
        if [ "$HAS_KNOWN_PROJECTS" -eq 1 ]; then
          NEW_INPUT_STYLE="display:none;"
        else
          NEW_INPUT_STYLE=""
        fi
        cat << SECTION_HEAD
<div class="date-section">
  <div class="date-header">
    <button type="button" class="mini toggle-btn" onclick="toggleSection(this)">▾ Comprimi</button>
    <h2>${DATE_HTML} (${COUNT_FOR_DATE} file)</h2>
    <label for="proj-${DATE_HTML}">Progetto/cartella:</label>
    <select class="project-select" id="proj-${DATE_HTML}" data-date="${DATE_HTML}" onchange="handleProjectChange(this)">${PROJECT_OPTIONS_HTML}<option value="__new__">+ Nuovo progetto…</option></select>
    <input type="text" class="project-new-input" data-date="${DATE_HTML}" placeholder="Nome progetto (anche drone/fpv)" value="" style="${NEW_INPUT_STYLE}">
    <button type="button" class="mini" onclick="pickFolder(this)" title="Scegli una cartella qualsiasi, anche su un altro disco">Sfoglia…</button>
    <span class="dest-path"></span>
    <button type="button" class="mini" onclick="selectSection(this, true)">Seleziona giornata</button>
    <button type="button" class="mini" onclick="selectSection(this, false)">Deseleziona giornata</button>
  </div>
  <div class="grid">
SECTION_HEAD

        awk -F'|' -v d="$DATE" '$2==d' "$NUMBERED_LIST" | while IFS='|' read -r CID D TYPE SRC; do
          [ -z "$SRC" ] && continue
          BN=$(basename "$SRC")
          BN_HTML=$(html_escape "$BN")
          MN_HTML=$(html_escape "${CID}__${BN}")
          if [ "$TYPE" = "VIDEO" ]; then
            WRAP_ATTRS="class=\"thumb-wrap video-thumb\" data-src=\"/media/${MN_HTML}\" onclick=\"playVideo(this)\" title=\"Clicca per riprodurre\""
            PLAY_ICON='<span class="play">▶</span>'
          else
            WRAP_ATTRS='class="thumb-wrap"'
            PLAY_ICON=''
          fi
          cat << CARD
<div class="card">
  <div ${WRAP_ATTRS}>
    <img loading="lazy" src="/thumbs/${MN_HTML}.png" alt="" data-media="${MN_HTML}" data-label="${BN_HTML}" onerror="handleImgError(this)">
    ${PLAY_ICON}
  </div>
  <div class="info">
    <input type="checkbox" checked data-id="${CID}">
    <span class="name">${BN_HTML}</span>
    <span class="badge ${TYPE}">${TYPE}</span>
  </div>
</div>
CARD
        done

        cat << 'SECTION_TAIL'
  </div>
</div>
SECTION_TAIL
      done < "$DATES_FILE"

      cat << 'HTML_TAIL'
<footer id="status">Per ogni giornata scegli un progetto dal menu (o "+ Nuovo progetto", anche con sottocartelle tipo drone/fpv) oppure "Sfoglia…" per una cartella qualsiasi, spunta o togli la spunta ai singoli file, poi clicca "Copia selezionati". La copia parte in background e questa pagina si chiude da sola; a fine copia arrivano suono e riepilogo. Per fermare una copia in corso: doppio click su "STOP Trasferimento" sul Desktop.</footer>
<script>
function updateCounter() {
  var boxes = document.querySelectorAll('.card input[type=checkbox]');
  var checked = document.querySelectorAll('.card input[type=checkbox]:checked');
  document.getElementById('counter').textContent = checked.length + ' di ' + boxes.length + ' selezionati';
  boxes.forEach(function(b) { b.closest('.card').classList.toggle('unchecked', !b.checked); });
}
function selectAll(state) {
  document.querySelectorAll('.card input[type=checkbox]').forEach(function(b) { b.checked = state; });
  updateCounter();
}
function selectSection(btn, state) {
  var section = btn.closest('.date-section');
  section.querySelectorAll('.card input[type=checkbox]').forEach(function(b) { b.checked = state; });
  updateCounter();
}
function toggleSection(btn) {
  var section = btn.closest('.date-section');
  var collapsed = section.classList.toggle('collapsed');
  btn.textContent = collapsed ? '▸ Espandi' : '▾ Comprimi';
}
function handleProjectChange(sel) {
  var newInput = sel.parentElement.querySelector('.project-new-input');
  if (sel.value === '__new__') {
    newInput.style.display = '';
    newInput.focus();
  } else {
    newInput.style.display = 'none';
  }
}
function setDest(section, path) {
  section.dataset.dest = path || '';
  var span = section.querySelector('.dest-path');
  var sel = section.querySelector('.project-select');
  var inp = section.querySelector('.project-new-input');
  span.textContent = '';
  if (path) {
    span.appendChild(document.createTextNode('→ ' + path));
    var x = document.createElement('a');
    x.href = '#'; x.textContent = '✕'; x.title = 'Torna a usare il progetto';
    x.onclick = function(e) { e.preventDefault(); setDest(section, ''); };
    span.appendChild(x);
    span.title = path;
    sel.disabled = true;
    inp.style.display = 'none';
  } else {
    sel.disabled = false;
    handleProjectChange(sel);
  }
}
function pickFolder(btn) {
  var sections = btn ? [btn.closest('.date-section')]
                     : Array.prototype.slice.call(document.querySelectorAll('.date-section'));
  var start = (sections[0] && sections[0].dataset.dest) || '';
  fetch('/pick', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({start: start})})
    .then(function(r) { return r.json(); })
    .then(function(d) { if (d && d.path) sections.forEach(function(sec) { setDest(sec, d.path); }); })
    .catch(function() {});
}
function applyToAll(project) {
  if (!project) return;
  document.querySelectorAll('.project-select').forEach(function(sel) {
    sel.value = project;
    setDest(sel.closest('.date-section'), '');
  });
}
function submitSelection(action) {
  var dsub = document.getElementById('opt-datesub').checked;
  var tsub = document.getElementById('opt-typesub').checked;
  var assignments = Array.prototype.map.call(document.querySelectorAll('.date-section'), function(section) {
    var sel = section.querySelector('.project-select');
    var date = sel.dataset.date;
    if (section.dataset.dest) {
      return {date: date, mode: 'path', value: section.dataset.dest, datesub: dsub, typesub: tsub};
    }
    var project = sel.value;
    if (project === '__new__' || !project) {
      project = section.querySelector('.project-new-input').value.trim() || date;
    }
    return {date: date, mode: 'proj', value: project, datesub: dsub, typesub: tsub};
  });
  var selected = Array.prototype.map.call(
    document.querySelectorAll('.card input[type=checkbox]:checked'),
    function(b) { return b.dataset.id; }
  );
  fetch('/submit', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({action: action, assignments: assignments, selected: selected})
  }).then(function() {
    document.querySelector('header').style.display = 'none';
    if (action === 'confirm') {
      document.getElementById('status').textContent = 'Copia avviata in background: a fine copia arrivano suono e riepilogo. Questa pagina si chiude da sola…';
      setTimeout(function() { window.close(); }, 1200);
    } else {
      document.getElementById('status').textContent = 'Import annullato, puoi chiudere questa scheda.';
    }
  });
}
document.addEventListener('change', function(e) { if (e.target.type === 'checkbox') updateCounter(); });
updateCounter();
</script>
</body>
</html>
HTML_TAIL
    } > "$GALLERY_DIR/gallery.html"

    RESULT_ACTION_FILE="$GALLERY_DIR/result_action.txt"
    RESULT_ASSIGN_FILE="$GALLERY_DIR/result_assign.txt"
    RESULT_SELECTED_FILE="$GALLERY_DIR/result_selected.txt"

    cat > "$GALLERY_DIR/server.py" << 'PYEOF'
import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.parse

ROOT = os.path.normpath(sys.argv[1])
PORT = int(sys.argv[2])
ACTION_FILE = sys.argv[3]
ASSIGN_FILE = sys.argv[4]
SELECTED_FILE = sys.argv[5]
DEFAULT_DIR = sys.argv[6] if len(sys.argv) > 6 else os.path.expanduser('~')
THUMB_SIZE = sys.argv[7] if len(sys.argv) > 7 else '320'

THUMBS = os.path.join(ROOT, 'thumbs')
MEDIA = os.path.join(ROOT, 'media')
CHUNK = 1024 * 1024                    # streaming a blocchi da 1 MB
THUMB_SEM = threading.Semaphore(2)     # max 2 miniature in parallelo
THUMB_LOCKS = {}
THUMB_GUARD = threading.Lock()
PICK_LOCK = threading.Lock()

MIME = {
    'html': 'text/html; charset=utf-8', 'png': 'image/png', 'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg', 'heic': 'image/heic', 'mp4': 'video/mp4',
    'mov': 'video/quicktime', 'm2ts': 'video/mp2t', 'mts': 'video/mp2t',
    'avi': 'video/x-msvideo', 'mxf': 'application/mxf',
}


def _lock_for(name):
    with THUMB_GUARD:
        return THUMB_LOCKS.setdefault(name, threading.Lock())


def make_thumb(media_name):
    """Genera (una volta sola) la miniatura di un file, su richiesta."""
    target = os.path.join(THUMBS, media_name + '.png')
    if os.path.isfile(target):
        return target
    src = os.path.join(MEDIA, media_name)
    if not os.path.lexists(src):
        return None
    with _lock_for(media_name):
        if os.path.isfile(target):
            return target
        with THUMB_SEM:
            tmp = tempfile.mkdtemp(dir=ROOT)
            try:
                subprocess.run(['nice', '-n', '10', 'qlmanage', '-t', '-s', THUMB_SIZE, '-o', tmp, src],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=40)
                pngs = [f for f in os.listdir(tmp) if f.lower().endswith('.png')]
                if pngs:
                    os.replace(os.path.join(tmp, pngs[0]), target)
            except Exception:
                pass
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
    return target if os.path.isfile(target) else None


def pick_folder(start):
    """Apre il selettore cartelle nativo di macOS e restituisce il percorso."""
    if not start or not os.path.isdir(start):
        start = DEFAULT_DIR if os.path.isdir(DEFAULT_DIR) else os.path.expanduser('~')
    esc = start.replace('\\', '\\\\').replace('"', '\\"')
    cmd = ['osascript',
           '-e', 'activate',
           '-e', 'set f to choose folder with prompt "Card Ingest: scegli la cartella di destinazione" default location (POSIX file "%s")' % esc,
           '-e', 'POSIX path of f']
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
    except Exception:
        return ''
    if r.returncode != 0:
        return ''
    return r.stdout.strip()


class Handler(http.server.BaseHTTPRequestHandler):
    def _guess_type(self, path):
        ext = path.rsplit('.', 1)[-1].lower() if '.' in path else ''
        return MIME.get(ext, 'application/octet-stream')

    def _empty(self, code):
        self.send_response(code)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def _json(self, obj):
        body = json.dumps(obj).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path):
        # Streaming a blocchi: prima un video senza "Range" veniva letto
        # TUTTO in memoria con f.read() (gigabyte per un MP4 lungo).
        if not os.path.isfile(path):
            return self._empty(404)
        size = os.path.getsize(path)
        start, end, status = 0, size - 1, 200
        rh = self.headers.get('Range')
        if rh and rh.startswith('bytes=') and size > 0:
            try:
                a, b = rh[6:].split(',')[0].strip().split('-')
                if a:
                    start = int(a)
                    end = int(b) if b else size - 1
                else:
                    start = max(size - int(b), 0)
                status = 206
            except Exception:
                start, end, status = 0, size - 1, 200
        end = min(end, size - 1)
        if size > 0 and start > end:
            self.send_response(416)
            self.send_header('Content-Range', 'bytes */%d' % size)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        length = (end - start + 1) if size > 0 else 0
        self.send_response(status)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Type', self._guess_type(path))
        self.send_header('Accept-Ranges', 'bytes')
        if status == 206:
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
        self.send_header('Content-Length', str(length))
        self.end_headers()
        try:
            with open(path, 'rb') as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    buf = f.read(min(CHUNK, remaining))
                    if not buf:
                        break
                    self.wfile.write(buf)
                    remaining -= len(buf)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def do_GET(self):
        path = urllib.parse.unquote(self.path.split('?')[0])
        if path == '/':
            path = '/gallery.html'
        full = os.path.normpath(os.path.join(ROOT, path.lstrip('/')))
        if not (full == ROOT or full.startswith(ROOT + os.sep)):
            return self._empty(403)
        if os.path.dirname(full) == THUMBS and full.endswith('.png') and not os.path.isfile(full):
            made = make_thumb(os.path.basename(full)[:-4])
            if not made:
                return self._empty(404)
        self._send_file(full)

    def _read_json(self):
        length = int(self.headers.get('Content-Length', 0) or 0)
        body = self.rfile.read(length) if length else b''
        try:
            return json.loads(body or b'{}')
        except Exception:
            return {}

    def do_POST(self):
        if self.path == '/pick':
            data = self._read_json()
            if not PICK_LOCK.acquire(blocking=False):
                return self._json({'path': '', 'busy': True})
            try:
                return self._json({'path': pick_folder(str(data.get('start', '') or ''))})
            finally:
                PICK_LOCK.release()

        if self.path != '/submit':
            return self._empty(404)
        data = self._read_json()
        action = data.get('action', 'cancel')
        assignments = data.get('assignments', []) or []
        selected = data.get('selected', []) or []

        def clean(v):
            return str(v if v is not None else '').replace('\n', ' ').replace('\r', ' ')

        with open(ASSIGN_FILE, 'w') as f:
            for a in assignments:
                d = clean(a.get('date')).replace('|', '-')
                mode = 'path' if a.get('mode') == 'path' else 'proj'
                v = clean(a.get('value'))
                if mode == 'proj':
                    v = v.replace('|', '-')
                elif '|' in v:
                    mode, v = 'proj', ''
                ds = '0' if a.get('datesub') is False else '1'
                ts = '0' if a.get('typesub') is False else '1'
                f.write('|'.join([d, mode, v, ds, ts]) + '\n')

        with open(SELECTED_FILE, 'w') as f:
            for x in selected:
                f.write(clean(x) + '\n')

        with open(ACTION_FILE, 'w') as f:
            f.write(str(action) + '\n')

        self._json({'ok': True})

    def log_message(self, format, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


Server(('127.0.0.1', PORT), Handler).serve_forever()
PYEOF

    # Libera la porta se e' rimasta occupata da un server di un giro
    # precedente che per qualche motivo non si e' chiuso bene
    lsof -ti "tcp:${GALLERY_PORT}" 2>/dev/null | xargs kill -9 2>/dev/null

    python3 "$GALLERY_DIR/server.py" "$GALLERY_DIR" "$GALLERY_PORT" "$RESULT_ACTION_FILE" "$RESULT_ASSIGN_FILE" "$RESULT_SELECTED_FILE" "$SSD_ROOT" "$GALLERY_THUMB_SIZE" >/dev/null 2>&1 &
    SERVER_PID=$!

    # Aspetta che il server risponda DAVVERO prima di aprire il browser,
    # invece di un sleep fisso che a volte non basta (scheda piena,
    # sistema sotto carico) e fa fallire l'apertura della pagina.
    SERVER_READY=0
    for SRV_TRY in $(seq 1 30); do
      if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${GALLERY_PORT}/"; then
        SERVER_READY=1
        break
      fi
      sleep 0.3
    done
    [ "$SERVER_READY" -eq 0 ] && log "ATTENZIONE: il server della galleria non risponde ancora dopo 9s per $VOL, provo comunque ad aprire il browser"
    # Chiudi eventuali schede rimaste da sessioni precedenti PRIMA di
    # aprire quella nuova (in background: se l'AppleScript non ha i
    # permessi di automazione non deve bloccare nulla), poi apri con un
    # URL UNICO: cosi' Safari non puo' riusare/mostrare una pagina
    # vecchia al posto della galleria appena creata.
    close_gallery_tab >/dev/null 2>&1 &
    sleep 1
    open "http://127.0.0.1:${GALLERY_PORT}/?sessione=$(date +%s)" 2>/dev/null

    log "In attesa della selezione nel browser per $VOL ($CANDIDATES candidati, $(wc -l < "$DATES_FILE" | tr -d ' ') giornate)"
    WAITED=0
    WAIT_BREAK_REASON=""
    while [ ! -f "$RESULT_ACTION_FILE" ] && [ "$WAITED" -lt "$GALLERY_TIMEOUT_SECS" ]; do
      if [ -f "$STOP_SIGNAL_FILE" ]; then
        log "Annullamento richiesto (STOP Trasferimento) durante la selezione per $VOL"
        rm -f "$STOP_SIGNAL_FILE"
        WAIT_BREAK_REASON="stop"
        break
      fi
      if [ ! -d "$VOL_PATH" ]; then
        log "Scheda $VOL rimossa mentre era in attesa della selezione: import annullato"
        WAIT_BREAK_REASON="rimossa"
        break
      fi
      sleep 2
      WAITED=$((WAITED + 2))
    done

    if [ ! -f "$RESULT_ACTION_FILE" ]; then
      [ -z "$WAIT_BREAK_REASON" ] && log "Timeout: nessuna risposta dal browser per $VOL, import annullato"
      ABORT=1
    else
      ACTION=$(head -1 "$RESULT_ACTION_FILE")
      if [ "$ACTION" != "confirm" ]; then
        log "Selezione annullata dall'utente (browser) per $VOL ($CANDIDATES file erano proposti)"
        ABORT=1
      else
        # --- Chi resta selezionato va copiato nel progetto scelto
        #     per la sua data; chi viene deselezionato finisce in
        #     blacklist (mai cancellato dalla scheda) ---
        TO_COPY_LIST=$(mktemp)
        CID=0
        while IFS='|' read -r DATE TYPE SRC KEY; do
          CID=$((CID + 1))
          [ -z "$SRC" ] && continue
          BN=$(basename "$SRC")
          if grep -qxF "$CID" "$RESULT_SELECTED_FILE"; then
            # Assegnazione della giornata: date|modo|valore|sottocartella_data|separa_tipo
            #   modo "proj" = progetto dentro SSD_ROOT (anche "drone/fpv")
            #   modo "path" = cartella qualsiasi scelta con "Sfoglia..."
            _AD=""; A_MODE=""; A_VALUE=""; A_DSUB="1"; A_TSUB="1"
            IFS='|' read -r _AD A_MODE A_VALUE A_DSUB A_TSUB <<< "$(grep "^${DATE}|" "$RESULT_ASSIGN_FILE" | head -1)"
            if [ "$A_MODE" = "path" ] && [ -n "$A_VALUE" ]; then
              DEST_BASE="${A_VALUE%/}"
              [ -z "$DEST_BASE" ] && DEST_BASE="/"
              LABEL="$DEST_BASE"
            else
              A_MODE="proj"
              PROJ=$(printf '%s' "${A_VALUE:-$DATE}" | sed -e 's#\.\./##g' -e 's#^/*##' -e 's#/*$##')
              [ -z "$PROJ" ] && PROJ="$DATE"
              DEST_BASE="$SSD_ROOT/$PROJ"
              LABEL="$PROJ"
            fi
            [ "$A_DSUB" = "0" ] || A_DSUB=1
            [ "$A_TSUB" = "0" ] || A_TSUB=1
            echo "${DATE}|${A_MODE}|${LABEL}|${DEST_BASE}|${A_DSUB}|${A_TSUB}|${TYPE}|${KEY##*|}|${SRC}" >> "$TO_COPY_LIST"
          else
            echo "$KEY" >> "$BLACKLIST_FILE"
            DESELECTED_COUNT=$((DESELECTED_COUNT + 1))
            log "Escluso e aggiunto alla blacklist: $BN"
          fi
        done < "$CANDIDATE_LIST"
      fi
    fi

    # --- Il browser non serve piu': lascia il tempo alla risposta HTTP
    #     di arrivare alla pagina, poi chiudi server, scheda del browser
    #     e file temporanei. La copia prosegue in background alla
    #     massima velocita', senza polling ne' server web attivo. ---
    sleep 1
    kill "$SERVER_PID" 2>/dev/null
    close_gallery_tab >/dev/null 2>&1 &
    rm -rf "$GALLERY_DIR"
    rm -rf "$KNOWN_PROJECTS_FILE" "$DATES_FILE"
    rm -f "$INDEX_FILE" "$MEDIA_LIST" "$CANDIDATE_LIST" "$NUMBERED_LIST"

  else
    # ==========================================================
    # --- Percorso di riserva: dialogo nativo con lista testuale
    #     (python3/qlmanage non disponibili). Un solo progetto
    #     per l'intera scheda, niente miniature, niente smistamento
    #     per data. ---
    # ==========================================================
    TODAY=$(date '+%Y-%m-%d')
    PROJECT=$(osascript -e "text returned of (display dialog \"Scheda rilevata: $VOL\nNome progetto (cartella su SSD):\" default answer \"$TODAY\" with title \"Card Ingest\" buttons {\"Annulla\",\"OK\"} default button \"OK\")" 2>/dev/null)
    if [ -z "$PROJECT" ]; then
      log "Import annullato dall'utente per $VOL (nessun nome progetto)"
      continue
    fi

    DEST_PROJECT_DIR="$SSD_ROOT/$PROJECT"
    mkdir -p "$DEST_PROJECT_DIR"

    INDEX_FILE=$(mktemp)
    build_dest_index "$DEST_PROJECT_DIR" "$INDEX_FILE"

    MEDIA_LIST=$(mktemp)
    find "$VOL_PATH" -type f "${VIDEO_FIND_ARGS[@]}" 2>/dev/null | sed 's/^/VIDEO|/' >  "$MEDIA_LIST"
    find "$VOL_PATH" -type f "${JPG_FIND_ARGS[@]}"   2>/dev/null | sed 's/^/JPG|/'   >> "$MEDIA_LIST"
    find "$VOL_PATH" -type f "${RAW_FIND_ARGS[@]}"   2>/dev/null | sed 's/^/RAW|/'   >> "$MEDIA_LIST"

    # Toglie le miniature JPEG dei video e (se abilitato) i clip proxy
    clean_media_list "$MEDIA_LIST"

    TOTAL=$(wc -l < "$MEDIA_LIST" | tr -d ' ')

    CANDIDATE_LIST=$(mktemp)
    COUNTS_FILE=$(mktemp)
    filter_candidates "$MEDIA_LIST" "$INDEX_FILE" "$CANDIDATE_LIST" "$COUNTS_FILE"
    SKIP=0
    BLACKLISTED_COUNT=0
    IFS='|' read -r SKIP BLACKLISTED_COUNT < "$COUNTS_FILE" || true
    rm -f "$COUNTS_FILE"

    CANDIDATES=$(wc -l < "$CANDIDATE_LIST" | tr -d ' ')

    if [ "$CANDIDATES" -eq 0 ]; then
      log "Nulla da proporre su $VOL (progetto: $PROJECT) - $TOTAL file, $SKIP gia' presenti, $BLACKLISTED_COUNT in blacklist"
      notify "Card Ingest" "Nessun file nuovo su '$VOL' (gia' importato o in blacklist)"
      rm -f "$INDEX_FILE" "$MEDIA_LIST" "$CANDIDATE_LIST"
      continue
    fi

    AS_LIST="{"
    FIRST=1
    while IFS='|' read -r FDATE TYPE SRC KEY; do
      [ -z "$SRC" ] && continue
      BN=$(basename "$SRC")
      BN_ESCAPED=$(as_escape "$BN")
      if [ "$FIRST" -eq 1 ]; then
        AS_LIST="${AS_LIST}\"${BN_ESCAPED}\""
        FIRST=0
      else
        AS_LIST="${AS_LIST}, \"${BN_ESCAPED}\""
      fi
    done < "$CANDIDATE_LIST"
    AS_LIST="${AS_LIST}}"

    PROMPT_TEXT="Scheda: $VOL — Progetto: $PROJECT\n\nTrovati $CANDIDATES file nuovi ($SKIP gia' presenti, $BLACKLISTED_COUNT in blacklist).\nDeseleziona quelli che NON vuoi importare (restano sulla scheda e non verranno piu' riproposti):"

    SELECTION_RESULT=$(osascript << APPLESCRIPT
set fileList to $AS_LIST
set chosen to choose from list fileList with title "Card Ingest" with prompt "$PROMPT_TEXT" default items fileList with multiple selections allowed
if chosen is false then
  return "CANCELLED"
else
  set AppleScript's text item delimiters to linefeed
  set chosenText to chosen as text
  set AppleScript's text item delimiters to ""
  return chosenText
end if
APPLESCRIPT
)

    if [ "$SELECTION_RESULT" = "CANCELLED" ] || [ -z "$SELECTION_RESULT" ]; then
      log "Selezione annullata dall'utente per $VOL ($CANDIDATES file erano proposti)"
      rm -f "$INDEX_FILE" "$MEDIA_LIST" "$CANDIDATE_LIST"
      continue
    fi

    SELECTED_FILE=$(mktemp)
    printf '%s\n' "$SELECTION_RESULT" > "$SELECTED_FILE"

    TO_COPY_LIST=$(mktemp)
    while IFS='|' read -r FDATE TYPE SRC KEY; do
      [ -z "$SRC" ] && continue
      BN=$(basename "$SRC")
      if grep -qxF "$BN" "$SELECTED_FILE"; then
        echo "${FDATE}|proj|${PROJECT}|${SSD_ROOT}/${PROJECT}|1|1|${TYPE}|${KEY##*|}|${SRC}" >> "$TO_COPY_LIST"
      else
        echo "$KEY" >> "$BLACKLIST_FILE"
        DESELECTED_COUNT=$((DESELECTED_COUNT + 1))
        log "Escluso e aggiunto alla blacklist: $BN"
      fi
    done < "$CANDIDATE_LIST"

    rm -f "$SELECTED_FILE" "$INDEX_FILE" "$MEDIA_LIST" "$CANDIDATE_LIST"
  fi

  if [ "$ABORT" -eq 1 ] || [ -z "$TO_COPY_LIST" ]; then
    [ -n "$TO_COPY_LIST" ] && rm -f "$TO_COPY_LIST"
    continue
  fi

  # --- Copia i file scelti, organizzati per progetto (scelto per
  #     ogni data) + data + tipo. Nessun aggiornamento da servire al
  #     browser: solo cp alla massima velocita'. caffeinate impedisce
  #     al Mac di addormentarsi a meta' trasferimento. ---
  COUNT_FILE=$(mktemp)
  ERROR_LIST=$(mktemp)
  TYPE_LOG=$(mktemp)
  PROJECT_LOG=$(mktemp)
  REMEMBER_LOG=$(mktemp)
  echo 0 > "$COUNT_FILE"
  TOTAL_TO_COPY=$(wc -l < "$TO_COPY_LIST" | tr -d ' ')

  ensure_stop_helper
  caffeinate -ims -w $$ >/dev/null 2>&1 &

  while IFS='|' read -r DATE DMODE PROJECT_NAME DEST_BASE DSUB TSUB TYPE SRC_SIZE SRC; do
    [ -z "$SRC" ] && continue

    # --- Stop richiesto dal Desktop ("STOP Trasferimento.command"):
    #     interrompi qui. I file gia' copiati restano, quelli che
    #     mancano restano sulla scheda (non in blacklist) e verranno
    #     riproposti al prossimo import. ---
    if [ -f "$STOP_SIGNAL_FILE" ]; then
      log "Trasferimento interrotto dall'utente ($(cat "$COUNT_FILE") di $TOTAL_TO_COPY file gia' copiati)"
      STOPPED_MIDWAY=1
      rm -f "$STOP_SIGNAL_FILE"
      break
    fi

    # --- Scheda tolta a meta' trasferimento: fermati senza riempire il
    #     log di errori, e dillo chiaramente nel recap. ---
    if [ ! -d "$VOL_PATH" ]; then
      log "Scheda $VOL rimossa durante il trasferimento ($(cat "$COUNT_FILE") di $TOTAL_TO_COPY file gia' copiati)"
      STOPPED_MIDWAY=1
      CARD_REMOVED=1
      break
    fi

    BASENAME=$(basename "$SRC")

    case "$TYPE" in
      JPG) SUBDIR="JPG" ;;
      RAW) SUBDIR="RAW" ;;
      *)   SUBDIR="VIDEO" ;;
    esac

    DEST_DIR="$DEST_BASE"
    [ "$DSUB" = "1" ] && DEST_DIR="$DEST_DIR/$DATE"
    [ "$TSUB" = "1" ] && DEST_DIR="$DEST_DIR/$SUBDIR"
    if ! mkdir -p "$DEST_DIR" 2>>"$LOG_FILE"; then
      log "ERRORE: non riesco a creare $DEST_DIR (disco scollegato o senza permessi?): $BASENAME"
      echo "$BASENAME" >> "$ERROR_LIST"
      continue
    fi

    DEST_FILE="$DEST_DIR/$BASENAME"
    if [ -e "$DEST_FILE" ]; then
      DEST_FILE="$DEST_DIR/${VOL}_${BASENAME}"
    fi

    if ! cp -p "$SRC" "$DEST_FILE" 2>>"$LOG_FILE"; then
      # Origine sparita: la scheda e' stata tolta o non e' piu' leggibile.
      # Fermati subito invece di accumulare un errore per ogni file.
      if [ ! -d "$VOL_PATH" ] || [ ! -e "$SRC" ]; then
        rm -f "$DEST_FILE"
        log "Scheda $VOL non piu' leggibile durante il trasferimento ($(cat "$COUNT_FILE") di $TOTAL_TO_COPY file gia' copiati)"
        STOPPED_MIDWAY=1
        CARD_REMOVED=1
        break
      fi
    fi

    # La dimensione dell'origine e' gia' nota dalla scansione iniziale:
    # una sola stat (sulla destinazione) per verificare la copia.
    DST_SIZE=$(stat -f%z "$DEST_FILE" 2>/dev/null || echo 0)
    if [ "$SRC_SIZE" != "$DST_SIZE" ]; then
      log "ERRORE copia (dimensione non corrisponde, verra' ritentato al prossimo giro): $BASENAME"
      rm -f "$DEST_FILE"
      echo "$BASENAME" >> "$ERROR_LIST"
    else
      log "Copiato [$TYPE -> $PROJECT_NAME]: $BASENAME -> $DEST_FILE"
      N=$(($(cat "$COUNT_FILE") + 1))
      echo "$N" > "$COUNT_FILE"
      echo "$TYPE" >> "$TYPE_LOG"
      echo "$DEST_BASE" >> "$PROJECT_LOG"
      [ "$DMODE" = "proj" ] && echo "$PROJECT_NAME" >> "$REMEMBER_LOG"
      echo "${BASENAME}|${SRC_SIZE}" >> "$DEST_INDEX_CACHE"
    fi
  done < "$TO_COPY_LIST"

  COPIED=$(cat "$COUNT_FILE")
  ERRORS=$(wc -l < "$ERROR_LIST" | tr -d ' ')

  # Ricorda i progetti usati per suggerirli la prossima volta
  sort -u "$REMEMBER_LOG" 2>/dev/null | while IFS= read -r P; do
    [ -n "$P" ] && remember_project "$P"
  done

  VIDEO_COPIED=$(grep -c "^VIDEO$" "$TYPE_LOG" 2>/dev/null)
  JPG_COPIED=$(grep -c "^JPG$" "$TYPE_LOG" 2>/dev/null)
  RAW_COPIED=$(grep -c "^RAW$" "$TYPE_LOG" 2>/dev/null)
  [ -z "$VIDEO_COPIED" ] && VIDEO_COPIED=0
  [ -z "$JPG_COPIED" ] && JPG_COPIED=0
  [ -z "$RAW_COPIED" ] && RAW_COPIED=0

  # --- Costruisce il testo di riepilogo ---
  RECAP="Scheda: $VOL
File copiati: $COPIED
Esclusi (blacklist): $DESELECTED_COUNT"

  if [ "$STOPPED_MIDWAY" -eq 1 ]; then
    REMAINING=$((TOTAL_TO_COPY - COPIED - ERRORS))
    if [ "$CARD_REMOVED" -eq 1 ]; then
      RECAP="$RECAP
SCHEDA RIMOSSA durante il trasferimento: $REMAINING file non ancora copiati sono rimasti sulla scheda (riproposti al prossimo import)."
    else
      RECAP="$RECAP
Trasferimento FERMATO manualmente (STOP Trasferimento): $REMAINING file non ancora copiati sono rimasti sulla scheda (non in blacklist, riproposti al prossimo import)."
    fi
  fi

  DETAILS=()
  [ "$VIDEO_COPIED" -gt 0 ] && DETAILS+=("$VIDEO_COPIED video")
  [ "$JPG_COPIED" -gt 0 ] && DETAILS+=("$JPG_COPIED JPG")
  [ "$RAW_COPIED" -gt 0 ] && DETAILS+=("$RAW_COPIED RAW")
  if [ ${#DETAILS[@]} -gt 0 ]; then
    DETAILS_TEXT="${DETAILS[0]}"
    for DIDX in "${!DETAILS[@]}"; do
      [ "$DIDX" -eq 0 ] && continue
      DETAILS_TEXT="${DETAILS_TEXT}, ${DETAILS[$DIDX]}"
    done
    RECAP="$RECAP
Tipi: $DETAILS_TEXT"
  fi

  if [ -s "$PROJECT_LOG" ]; then
    RECAP="$RECAP
Progetti:"
    PROJECT_COUNTS_FILE=$(mktemp)
    sort "$PROJECT_LOG" | uniq -c > "$PROJECT_COUNTS_FILE"
    while read -r CNT PNAME; do
      [ -z "$PNAME" ] && continue
      RECAP="$RECAP
  - $CNT file in $PNAME"
    done < "$PROJECT_COUNTS_FILE"
    rm -f "$PROJECT_COUNTS_FILE"
  fi

  if [ "$ERRORS" -gt 0 ]; then
    RECAP="$RECAP
Errori di copia ($ERRORS, verranno ritentati al prossimo import):"
    ERR_SHOWN=0
    while IFS= read -r EFILE; do
      [ "$ERR_SHOWN" -ge 10 ] && break
      RECAP="$RECAP
  - $EFILE"
      ERR_SHOWN=$((ERR_SHOWN + 1))
    done < "$ERROR_LIST"
    [ "$ERRORS" -gt 10 ] && RECAP="$RECAP
  - ... e altri $((ERRORS - 10))"
  fi

  rm -f "$TO_COPY_LIST" "$COUNT_FILE" "$ERROR_LIST" "$TYPE_LOG" "$PROJECT_LOG" "$REMEMBER_LOG"

  show_recap "Card Ingest completato" "$RECAP"
  log "Import completato per $VOL: $COPIED copiati ($VIDEO_COPIED video, $JPG_COPIED JPG, $RAW_COPIED RAW), $DESELECTED_COUNT esclusi, $ERRORS errori"
done

# --- Recupero degli eventi persi -------------------------------------
# Se mentre questo giro lavorava (galleria aperta, copia lunga) una
# scheda e' stata tolta e/o inserita, l'evento launchd di quel momento
# ha lanciato un'esecuzione che e' uscita subito per via del lock, SENZA
# aggiornare known_volumes.txt: la scheda reinserita risulterebbe "gia'
# nota" e verrebbe ignorata per sempre. Qui, a lavoro finito, si
# ricontrolla lo stato reale di /Volumes: se e' cambiato rispetto alla
# fotografia iniziale, si riparte da capo (il lock viene rilasciato e
# lo script si rilancia su se stesso).
LATEST_VOLUMES=$(ls -1 /Volumes 2>/dev/null)
if [ "$LATEST_VOLUMES" != "$(cat "$KNOWN_VOLUMES_FILE" 2>/dev/null)" ]; then
  log "I volumi sono cambiati durante l'esecuzione: ricontrollo"
  [ -n "$MONITOR_PID" ] && kill "$MONITOR_PID" 2>/dev/null
  rm -rf "$LOCK_DIR"
  trap - EXIT
  exec /bin/bash "$0"
fi
