# Card Ingest

**Importatore automatico e gratuito di schede di memoria per macOS.** Inserisci una SD, la scheda del drone o una chiavetta e nel browser si apre una galleria: scegli cosa tenere, decidi dove va ogni giornata e Card Ingest copia tutto in una struttura ordinata, avvisandoti a fine copia.

*[Read in English](README.md)*

<!-- Aggiungi qui uno screenshot o una GIF della galleria: docs/gallery.png -->

## Funzionalità

- **Parte da solo** quando colleghi una scheda (a eventi tramite `launchd`, nessuna app da tenere aperta).
- **Galleria con miniature** raggruppate per giorno di ripresa; i video si riproducono con un clic.
- **Destinazione per giornata**: un progetto esistente, uno nuovo (anche con sottocartelle tipo `drone/fpv`) oppure **qualsiasi cartella** con "Sfoglia…", anche su un altro disco.
- **Struttura ordinata**: `Progetto/AAAA-MM-GG/VIDEO|JPG|RAW`, con sottocartella data e separazione per tipo disattivabili.
- **Mai doppioni**: i file già presenti sul disco di destinazione vengono saltati.
- **Blacklist**: i file che togli non vengono più proposti (e **non** vengono cancellati dalla scheda).
- **Conosce le videocamere**: salta le miniature JPEG dei video (`T01.JPG`) e i clip proxy (`S03.MP4`).
- **Ignora ciò che non è una scheda**: immagini disco (`.dmg`) dei programmi scaricati, installer, volumi di sistema.
- **Copia sicura**: controllo dimensione file per file, il Mac non va in stop durante il trasferimento, puoi togliere e rimettere la scheda in qualsiasi momento.
- Suono e riepilogo a fine copia. Per fermare una copia: doppio clic su **STOP Trasferimento** sulla Scrivania.

## Requisiti

- macOS (testato su Apple Silicon)
- `python3` per la galleria: se manca, `xcode-select --install`. Senza, Card Ingest usa una semplice finestra con l'elenco dei file.

## Installazione

```bash
git clone https://github.com/<tuo-utente>/card-ingest.git
cd card-ingest
./install.sh
```

L'installer chiede la cartella di destinazione (es. `/Volumes/MioSSD/Progetti`), installa lo script in `~/Library/Application Support/CardIngest` e registra un LaunchAgent. Rilancialo quando vuoi per aggiornare.

La prima volta macOS può chiedere dei permessi (Scrivania, controllo del browser per chiudere la galleria, selettore cartelle): accettali.

## Uso

1. Inserisci la scheda: se contiene foto o video non ancora importati, si apre la galleria.
2. Per ogni giornata scegli un progetto, scrivi un nome nuovo o premi **Sfoglia…**.
3. Togli la spunta a ciò che non vuoi e premi **Copia selezionati**.
4. La pagina si chiude e la copia continua in background; alla fine arrivano suono e riepilogo.

Se il disco di destinazione non è collegato ricevi una notifica, e la scheda ti viene riproposta appena lo colleghi.

## Impostazioni

Tutto in `~/.card_ingest/config.sh` (vedi [`config.example.sh`](config.example.sh)): destinazione, estensioni, gestione dei proxy, timeout e porta della galleria.

| File in `~/.card_ingest/` | Cos'è |
|---|---|
| `config.sh` | le tue impostazioni |
| `blacklist.txt` | file esclusi: cancella una riga per ripescare un file |
| `recent_projects.txt` | progetti proposti per primi nel menu |
| `ingest.log` | cosa è successo, file per file |
| `dest_index.meta` | cancellalo per forzare una nuova scansione della destinazione |

## Disinstallazione

```bash
./uninstall.sh           # tiene impostazioni e blacklist
./uninstall.sh --purge   # rimuove tutto
```

Le foto e i video copiati non vengono mai toccati.

## Supporta il progetto

Card Ingest è gratuito e open source. Se ti fa risparmiare tempo puoi sostenerlo:
<!-- sostituisci con i tuoi link -->
- GitHub Sponsors: `https://github.com/sponsors/<tuo-utente>`
- Ko-fi: `https://ko-fi.com/<tuo-utente>`

Segnalazioni di bug e pull request sono benvenute.

## Licenza

[MIT](LICENSE)
