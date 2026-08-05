# ActiveAnalytics — Guida all'uso

ActiveAnalytics è un engine Rails montabile, alternativa self-hosted a Hotjar: registra le
sessioni di navigazione degli utenti, le riproduce in una dashboard con un player video-like,
maschera i dati sensibili **nel browser del visitatore** (prima che lascino la pagina),
rileva i segnali di frustrazione con un'analisi comportamentale (opzionalmente riassunta da
un LLM), disegna heatmap per pagina e raccoglie web analytics di base per tutti i
visitatori. Tutti i dati restano nel database della tua applicazione.

---

## 1. Installazione

Da RubyGems (quando la gem è pubblicata):

```ruby
# Gemfile
gem "active_analytics"
```

**Da GitHub** (per usare il repository direttamente, senza pubblicazione su RubyGems):

```ruby
# Gemfile
gem "active_analytics", github: "giovapanasiti/active_analytics"

# Per bloccare una versione precisa, aggiungi branch, tag o commit:
# gem "active_analytics", github: "giovapanasiti/active_analytics", branch: "main"
# gem "active_analytics", github: "giovapanasiti/active_analytics", tag: "v0.1.0"
# gem "active_analytics", github: "giovapanasiti/active_analytics", ref: "abc1234"
```

Se il repository è privato, configura prima le credenziali per Bundler
(`bundle config github.com TUO_TOKEN`) oppure usa l'URL SSH:

```ruby
gem "active_analytics", git: "git@github.com:giovapanasiti/active_analytics.git"
```

Per lo sviluppo in locale puoi puntare direttamente alla cartella del progetto:

```ruby
gem "active_analytics", path: "../active_analytics"
```

```bash
bundle install
bin/rails active_analytics:install:migrations
bin/rails db:migrate
```

Monta l'engine e aggiungi il tag di registrazione al layout:

```ruby
# config/routes.rb
mount ActiveAnalytics::Engine => "/analytics"
```

```erb
<%# app/views/layouts/application.html.erb, prima di </body> %>
<%= active_analytics_tag %>
```

Fatto. Da questo momento:

| Cosa | Dove |
|---|---|
| Dashboard (Overview, Recordings, Heatmaps) | `https://tuosito.com/analytics` |
| Endpoint di ingestione sessioni | `POST /analytics/events` (usato dal recorder JS) |
| Endpoint pageview | `POST /analytics/pageviews` (beacon, tutti i visitatori) |

Il tag inietta la configurazione e carica `recorder.js` (nessuna dipendenza esterna, nessun
CDN, nessuna build). Su una pagina esclusa o con l'engine disabilitato il tag non renderizza
nulla.

## 2. Proteggi la dashboard

La dashboard non ha autenticazione propria: proteggila nel router dell'app host. Esempio con
Devise:

```ruby
authenticate :user, ->(u) { u.admin? } do
  mount ActiveAnalytics::Engine => "/analytics"
end
```

Gli endpoint `events` e `pageviews` sono volutamente pubblici (come ogni beacon di
analytics): accettano solo JSON validato con limiti di dimensione.

## 3. Configurazione

Crea `config/initializers/active_analytics.rb`:

```ruby
ActiveAnalytics.configure do |config|
  config.enabled           = Rails.env.production? # interruttore generale
  config.sample_rate       = 0.5                   # registra il 50% delle sessioni
  config.mask_all_text     = false                 # true = maschera OGNI testo della pagina
  config.ignored_paths     = ["/admin", %r{^/internal}]
  config.retention_days    = 30                    # usato da active_analytics:purge
  config.session_timeout   = 30 * 60               # secondi di inattività che chiudono una sessione
  config.max_batch_bytes   = 1_000_000             # limite payload ingestione
  config.auto_analyze      = true                  # analizza le sessioni concluse in automatico
  config.visitor_ip_storage = :hashed              # :hashed (default) o :raw

  # Riassunti AI (opzionali) — vedi §7
  config.ai_summarizer     = :anthropic
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  config.anthropic_model   = "claude-opus-5"
end
```

Note:
- `sample_rate` riguarda solo la **registrazione delle sessioni**; le analytics di base
  (§8) contano comunque tutti i visitatori.
- `ignored_paths` accetta prefissi stringa o Regexp e disattiva il tag su quelle pagine.
- I visitatori con **Do Not Track** attivo non vengono né registrati né conteggiati.

## 4. Masking e privacy

Il masking avviene **nel browser**, al momento della cattura: i valori mascherati non
raggiungono mai il server.

| Regola | Comportamento |
|---|---|
| `input[type=password]`, `email`, `tel`, autocomplete `cc-*` | sempre mascherati (`••••••••`), non disattivabile |
| ogni altro campo form | mascherato di default |
| `data-aa-unmask` sull'elemento | mostra il valore (solo campi non sensibili) |
| `data-aa-mask` su un contenitore | ogni testo al suo interno diventa `***` (lunghezza preservata) |
| `data-aa-block` | l'elemento sparisce dalla registrazione (placeholder con le stesse dimensioni) |
| `config.mask_all_text = true` | maschera tutti i testi della pagina, salvo sottoalberi `data-aa-unmask` |

Esempi:

```html
<div data-aa-mask>Mario Rossi — Via Roma 1, Milano</div>   <!-- testo → asterischi -->
<input type="text" name="nickname" data-aa-unmask>          <!-- valore visibile nel replay -->
<div id="documento-riservato" data-aa-block>...</div>       <!-- mai registrato -->
```

## 5. Registrazioni e replay

**Recordings** elenca le sessioni con filtri (URL, solo-con-errori, durata minima, date) e
per ciascuna: dispositivo, durata, pagine, click, errori JS e **frustration score** (badge
verde < 30, ambra < 60, rosso ≥ 60).

Aprendo una sessione trovi:
- **metadati** (inizio, durata, viewport, user agent, referrer) e il percorso pagine;
- **insights** dell'analisi (§6) — il timestamp di ognuno è un pulsante che fa seek nel
  player al momento esatto;
- **il player**: play/pausa, barra di avanzamento con i marker degli insight, velocità
  1x/2x/4x, "Skip pauses" (i tempi morti > 4s vengono saltati). Il replay ricostruisce il
  DOM registrato in un iframe sandbox: nessuno script della pagina originale viene eseguito.

Una sessione si considera conclusa dopo `session_timeout` secondi di inattività. Con
`auto_analyze` attivo, le sessioni concluse vengono analizzate automaticamente al primo
traffico utile; puoi comunque forzare l'analisi con il pulsante **Run analysis** o via rake.

## 6. Monitoraggio AI del comportamento

L'analisi rileva questi insight:

| Insight | Significato | Peso sullo score |
|---|---|---|
| `rage_click` | ≥ 3 click rapidi nello stesso punto | 15 |
| `form_abandon` | form iniziato e abbandonato senza invio | 10 |
| `js_error` | errore JavaScript nel browser dell'utente | 10 |
| `dead_click` | click che non produce alcun effetto | 5 |
| `thrash` | movimenti del cursore erratici/frustrati | 5 |
| `u_turn` | arriva su una pagina e torna subito indietro | 5 |

La somma pesata (limitata a 0–100) è il **frustration score** della sessione: usalo per
ordinare mentalmente cosa guardare prima — le sessioni rosse sono quelle dove qualcosa è
andato storto.

## 7. Riassunti in linguaggio naturale (LLM)

Con un backend configurato, ogni analisi produce anche una card "AI summary": un riassunto
comportamentale ≤ 120 parole con un suggerimento pratico. L'LLM riceve **solo un digest**
(URL, tempi, contatori, insight) — mai testi o valori digitati dagli utenti.

Due modi per attivarlo:

```ruby
# 1. Client Anthropic integrato (zero dipendenze)
config.ai_summarizer     = :anthropic
config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]

# 2. Qualsiasi callable: ricevi il prompt, restituisci una stringa
config.ai_summarizer = ->(prompt) { MioClientLLM.completa(prompt) }
```

Senza configurazione, l'analisi euristica funziona comunque: semplicemente niente card.

## 8. Analytics di base (Overview)

La home della dashboard è **Overview**: page views, visitatori unici, views per visitor,
grafico giornaliero (7/30/90 giorni), top pagine, referrer, browser e dispositivi.

- Conteggia **tutti** i visitatori (anche quelli esclusi dal campionamento delle
  registrazioni) tramite un beacon inviato a ogni caricamento pagina e navigazione SPA.
- I **visitatori unici** derivano da un digest SHA-256 giornaliero di IP + user agent:
  nessun IP in chiaro nel database. Se ti serve l'IP reale (e hai la base giuridica per
  conservarlo): `config.visitor_ip_storage = :raw` — in tal caso le righe visitatore
  vengono eliminate dal purge dopo `retention_days`.
- I rollup (views, referrer, browser) sono aggregati anonimi e vengono conservati per
  sempre, anche dopo la cancellazione delle registrazioni.

## 9. Heatmap

**Heatmaps** elenca le pagine con dati aggregati; per ogni pagina scegli il tipo e il
dispositivo (desktop/tablet/mobile — mai mescolati, i layout differiscono):

- **Move** — densità dei movimenti di mouse e dita (touch);
- **Click** — densità di click e tap;
- **Scroll** — scroll-depth: quota di pageview che raggiunge ogni punto della pagina, con
  le soglie 75/50/25%.

Le mappe si disegnano sopra lo **snapshot DOM reale** più recente della pagina. I dati
arrivano dall'analisi delle sessioni (§5): se una heatmap è vuota, probabilmente le
sessioni non sono ancora state analizzate — esegui `bin/rails active_analytics:analyze`.
Le celle heatmap sono contatori anonimi e sopravvivono al purge.

## 10. Manutenzione

```bash
bin/rails active_analytics:analyze  # analizza le sessioni concluse non ancora analizzate
bin/rails active_analytics:purge    # elimina registrazioni (e visitor-key) oltre retention_days
```

Mettili in cron (o solid_queue recurring):

```
*/15 * * * *  cd /app && bin/rails active_analytics:analyze
0 4 * * *     cd /app && bin/rails active_analytics:purge
```

Con `auto_analyze` attivo il primo comando è una rete di sicurezza più che una necessità.

## 11. Risoluzione problemi

| Sintomo | Verifica |
|---|---|
| Nessuna sessione registrata | `config.enabled`? `sample_rate` troppo basso? pagina in `ignored_paths`? il browser ha Do Not Track? il tag è nel layout? |
| Sessioni senza insight / score "—" | l'analisi non è ancora girata: pulsante "Run analysis" o rake `analyze` |
| Heatmap vuote | come sopra (le celle si popolano durante l'analisi); controlla anche il device selezionato |
| Nessun dato touch nelle heatmap | i dati touch esistono solo per le visite registrate dopo l'introduzione della cattura touch |
| Overview a zero | il beacon parte dal tag: stessi requisiti della prima riga (tranne il sampling, che non conta) |
| Replay "spoglio" (senza stili) | i CSS della pagina vengono caricati dagli URL assoluti registrati: devono essere raggiungibili da chi guarda il replay |
| Voglio azzerare tutto | le tabelle `active_analytics_*` si possono troncare senza effetti collaterali |
| Replay vuoto / "No pages recorded" su registrazioni vecchie | causato dal limite di 64KB di `fetch keepalive`/`sendBeacon`: lo snapshot iniziale (grande) veniva scartato silenziosamente. Risolto dalle regole di trasporto del flush (fetch senza keepalive per i flush periodici, retry singolo, snapshot inviato subito); le registrazioni vecchie senza snapshot non sono recuperabili |

## 12. Provarlo in locale

Il repo include un'app demo già configurata:

```bash
bin/rails test                     # suite completa
cd test/dummy && bin/rails server  # demo su http://localhost:3000
```

Naviga la home (form, pulsanti, blocco mascherato), poi apri `/analytics`: troverai la
sessione appena registrata, potrai riprodurla, analizzarla e vedere Overview e heatmap
popolarsi.
