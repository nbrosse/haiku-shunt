# haiku-shunt, fichier par fichier

Guide de lecture du repo. Rédigé le 2026-09-10, puis mis à jour après la
simplification de la mesure (voir section 9).

## 0. L'idée en une minute

C'est un **plugin Claude Code**. Quand le modèle principal (Sonnet ou Opus,
qu'on appelle ici « parent » ou « orchestrateur ») veut lire un gros fichier en
entier, un hook `PreToolUse` **refuse** l'appel. Le message de refus lui propose
trois alternatives :

1. déléguer la lecture à un sous-agent **Haiku** (`bulk-reader`), qui lit le
   fichier dans *son* propre contexte et renvoie un résumé d'environ 300 tokens ;
2. relire avec `offset`/`limit` (lecture fenêtrée) ;
3. utiliser `Grep`.

**Pourquoi ça fait économiser :** l'écart de tarif Haiku/Sonnet (×2) compte peu.
Ce qui compte, c'est que tout ce qui entre dans le contexte du parent est
**renvoyé à chaque tour suivant**. Un fichier de 30K tokens lu au tour 3 d'une
session de 40 tours est refacturé environ 37 fois (à ~10 % grâce au cache). S'il
n'entre jamais dans le contexte, tous ces renvois disparaissent.

Pour savoir si ça rapporte vraiment, le repo s'appuie sur un **benchmark A/B**
(même tâche avec et sans plugin, coût lu dans les stats de Claude Code). Le
plugin lui-même se contente de compter ce que font ses hooks.

```
Parent → Read(gros fichier) → read-guard.sh → deny + message → events-*.jsonl
       → Task(bulk-reader) → Haiku lit (ses Read passent : il est exempté)
       → résumé compact → le parent continue

bench/ab.sh → claude -p avec/sans plugin → total_cost_usd de Claude Code
```

---

## 1. Métadonnées du plugin

| Fichier | Rôle |
|---|---|
| `.claude-plugin/plugin.json` | Manifeste du plugin : nom, version 0.1.0, auteur, licence. Claude Code découvre automatiquement `hooks/hooks.json`, `agents/` et `skills/` à partir de la racine. |
| `.claude-plugin/marketplace.json` | Fait du repo un « marketplace » local contenant un seul plugin (`source: "./"`). C'est ce qui permet `claude plugin marketplace add ./haiku-shunt`. |
| `LICENSE` / `NOTICE` | Apache-2.0. `NOTICE` crédite l'idée au plugin `shunt` de Spotify, qui passe par `portal-cli` et Gemini Flash. Ici, le worker est un simple sous-agent natif : pas de service externe, pas de clé API. |
| `.gitignore` | Ignore les fixtures et résultats d'évals, `.haiku-shunt/` (logs locaux) et les caches Python. |

## 2. `config/defaults.json`, la source unique des paramètres

- **`thresholds`** :
  - `min_lines: 350` et `min_bytes: 8000` : un fichier est bloqué seulement
    s'il dépasse les **deux** seuils.
  - `max_bytes: 200000` : au-delà, le fichier est bloqué quel que soit son
    nombre de lignes, pour attraper les bundles minifiés qui tiennent sur une
    seule ligne.
  - `read_truncation_lines: 2000` : l'outil Read s'arrête à ~2000 lignes, donc
    l'estimation de tokens loggée ne compte pas au-delà.
  - `max_denies_per_path: 2` et `deny_ttl_seconds: 1800` : le disjoncteur
    anti-boucle.
- **`policy`** :
  - `mode` : `deny` refuse la lecture, `warn` se contente de glisser un conseil
    via `additionalContext`.
  - `worker_agents` : les agents à ne jamais bloquer.
  - `reader_commands` : les commandes shell surveillées
    (`cat less more bat head tail`).
  - `exempt_extensions` : binaires, images, archives, etc.
- **`pricing_usd_per_mtok`** : tarifs par modèle et multiplicateurs de cache
  (écriture ×2 pour la session principale, qui utilise le cache d'une heure,
  ×1.25 pour les sous-agents, qui utilisent celui de 5 minutes ; lecture
  ×0.10). Ils ne servent plus qu'au calcul du point
  mort de `doctor` ; les coûts du benchmark viennent de Claude Code.
- **`estimation`** : 4 octets par token, coût fixe d'un worker
  (`worker_floor_tokens: 14600`), `R` supposé = 12 tours restants, taux de hit
  cache supposé = 0.9. Tous utilisés par le point mort.

Chaque seuil peut être surchargé par une variable d'environnement `SHUNT_*`
(voir `common.sh`).

---

## 3. Les hooks, le cœur du plugin

### `hooks/hooks.json`

Déclare deux hooks :

- `PreToolUse` avec matcher `Read`, qui lance `read-guard.sh` ;
- `PreToolUse` avec matcher `Bash`, qui lance `bash-guard.sh`.

Chaque commande reçoit `HAIKU_SHUNT_PLUGIN_DATA=${CLAUDE_PLUGIN_DATA}`, qui sert
à choisir où écrire les logs.

### `hooks/lib/common.sh`, le runtime partagé

C'est la bibliothèque la plus importante. Son **invariant** : un hook ne doit
jamais casser une session, donc chaque chemin se termine par `exit 0`.

- **Pas de `set -e`**, mais `trap shunt_fail_open ERR` (`common.sh:24`) : une
  erreur imprévue journalise `internal_error` et laisse passer l'appel.
- **`shunt_allow`** (`:15`) : autoriser, c'est **ne rien émettre**. Émettre
  `permissionDecision: "allow"` court-circuiterait les règles de permission de
  l'utilisateur.
- **`shunt_load_config`** (`:32`) : un seul appel à `jq` extrait toute la config
  sous forme d'affectations shell (`@sh`), avec des valeurs par défaut codées en
  dur si `jq` échoue, puis applique les surcharges d'environnement. `shunt_int`
  rejette les valeurs non numériques. Un seul spawn parce que ce code tourne à
  **chaque** appel Read et Bash.
- **`shunt_log_dir`** (`:63`) : le répertoire de logs est le premier candidat
  inscriptible parmi `SHUNT_LOG_DIR`, les données du plugin,
  `$CLAUDE_PROJECT_DIR/.haiku-shunt`, puis `~/.local/state/haiku-shunt`.
- **`shunt_append`** (`:83`) : une ligne JSONL est écrite en **un seul
  `write(2)` de 4000 octets au plus**. En mode `O_APPEND` sur un système de
  fichiers local, c'est atomique : deux hooks concurrents ne peuvent pas
  entrelacer leurs lignes. Au-delà de 3900 caractères, le record est tronqué
  (commande à 200 caractères, 4 chemins). Sur NFS, `SHUNT_LOG_LOCK=1` ajoute un
  `flock`.
- **`shunt_log`** (`:107`) : construit l'événement `hook_decision` : session,
  `agent_type`, décision, `reason_code`, chemins, tokens évités (plafonnés et
  non plafonnés), latence.
- **`shunt_deny_count`** (`:135`) : le **disjoncteur**. Un fichier
  `state/<session>.denies` associe à chaque chemin (haché en sha256) un
  compteur et un timestamp, le tout sous `flock`. Le calcul se fait dans un
  sous-shell `( … )`, donc la variable `n` ne remonte pas au shell parent :
  elle transite par un fichier `.count`. Au-delà de 30 minutes (TTL), le
  compteur repart à 1.
- **`shunt_probe`** (`:160`) : sonde le fichier. Il doit exister, être un
  fichier régulier (`-f` exclut `/dev/zero`, sur lequel `wc -l` ne rendrait
  jamais la main), être lisible, et ne pas avoir une extension exemptée. Un
  octet NUL dans les 8 premiers Ko signale un binaire. Le nombre de lignes est
  corrigé de +1 si la dernière ligne n'a pas de `\n`.
- **`shunt_est_tokens`** : `octets/4 + lignes×1.5`.
- **`shunt_capped_tokens`** : pour Read uniquement, plafonne à 2000 lignes,
  parce que c'est tout ce que Read aurait vraiment injecté.

### `hooks/lib/decide.sh`, la décision et le message

- **`shunt_deny_reason`** : le texte du refus. Le commentaire l'appelle
  *« la chaîne la plus importante du repo »* : c'est la seule chose qui dit au
  modèle bloqué comment continuer. Il liste les 3 options et rappelle de relire
  une plage avec une lecture fenêtrée avant toute édition. Il donne la taille
  maximale d'une fenêtre (`MIN_LINES` lignes) et déconseille de lire tout le
  fichier par fenêtres : l'ancienne version promettait que les fenêtres étaient
  « toujours autorisées », et le modèle en envoyait de plus grandes que le seuil.
- **`shunt_deny`** : incrémente le compteur. Au-delà de `MAX_DENIES` (donc à la
  3ᵉ tentative), la lecture passe (`deny_cap_reached`). Sinon, émet le JSON
  `hookSpecificOutput`, avec `permissionDecision:"deny"` en mode deny ou
  `additionalContext` en mode warn.
- **`shunt_common_guards`** : applique `SHUNT_DISABLE`, puis la **garde
  anti-récursion**. Si `agent_type` est présent, on retire le namespace
  (`${AGENT_TYPE##*:}`). Si la base est l'un de nos workers, la lecture passe :
  sinon le worker se ferait bloquer la lecture même qu'on lui a déléguée, ce
  qui serait un deadlock. Un autre sous-agent (Explore, Plan…) est bloqué comme
  le parent, sauf si `SHUNT_SHUNT_OTHER_AGENTS=0`.

### `hooks/read-guard.sh`, la garde sur Read

Déroulé :

1. Lit le payload sur stdin (timeout 2 s). Du JSON invalide est journalisé puis
   laissé passer.
2. Extrait les champs avec `jq` + `@sh` + `eval`, en normalisant tout ce qui
   n'est pas du bon type en chaîne vide. Le `@sh` échappe tout, donc l'`eval`
   est sûr.
3. Si `limit` ≤ `MIN_LINES`, la lecture est fenêtrée et **toujours
   autorisée**, sans même sonder le fichier : c'est précisément ce qu'on
   demande au modèle de faire après un refus.
4. Sinon, résout le chemin en absolu (`~`, chemin relatif au `cwd`), exempte
   les logs du plugin lui-même et sonde le fichier.
5. Toute autre lecture avec `offset` ou `limit` est jugée sur les lignes
   qu'elle **renverra réellement** : `min(limit, lignes restantes après
   offset)`, avec 2000 (la limite de Read) quand `limit` est absent. Au-delà du
   seuil (et du plancher en octets), refus `window_over_threshold`.
   `Read(offset=1)` est donc refusé comme une lecture complète, alors que
   `offset=4900, limit=500` sur 5000 lignes (101 lignes renvoyées) passe.
6. Pour une lecture complète, refuse si `bytes > MAX_BYTES`, ou si
   `lignes > MIN_LINES` **et** `bytes > MIN_BYTES`.
7. Sinon, autorise avec le code `under_threshold` ou `under_byte_floor`.

### `hooks/bash-guard.sh`, la garde sur Bash

Elle attrape les `cat gros.txt` qui contournent Read.

1. **Chemin rapide** (`:37`) : si aucun nom de commande lectrice n'apparaît
   dans la commande (cas de `git`, `npm`, `pytest`…), elle sort immédiatement,
   sans démarrer Python.
2. Sinon, elle délègue l'analyse à `bashparse.py` (timeout 3 s). Si l'analyse
   échoue, la commande passe.
3. Si le verdict est `check`, elle reçoit une liste de fichiers, chacun avec son
   `reader`, sa borne `bound_lines` et sa ligne de départ `from_line`. Au plus
   16 opérandes sont sondés, pour ne pas dépasser `ARG_MAX`.
4. Pour chaque fichier, elle calcule `eff`, les **lignes effectivement émises
   sur stdout** : `tail -n +4900` sur 5000 lignes donne 101 ; un `| head -50`
   plafonne à 50.
5. Elle refuse si le **premier** fichier qui dépasse vérifie
   `eff > MIN_LINES && bytes > MIN_BYTES`, ou s'il est énorme en octets et lu
   sans borne.

Le séparateur `\x1f` (`:50`) est un détail subtil. Avec une tabulation, `read`
fusionnerait les champs vides, parce que la tabulation est un blanc au sens
d'`IFS`.

### `hooks/lib/bashparse.py`, le mini-parseur shell

Il répond à une seule question : **cette commande met-elle le contenu d'un
fichier sous les yeux du modèle ?**

- **`scan()`** : découpe la commande en segments sur `|`, `||`, `&&`, `;`, `&`
  et les retours à la ligne, en respectant les quotes. En chemin, il note pour
  chaque segment :
  - `redirected` : stdout part ailleurs (`>`, `&>`). Attention, `2>/dev/null`
    ne redirige **que** stderr : ce n'est pas une redirection de stdout.
  - `stdin_file` : `cat < gros` déverse bien le fichier.
  - `heredoc` : dès `<<`, il arrête de scanner, car le corps est de la donnée.
  - `subst` : présence de `$(...)` ou de backticks.
  - `piped_out` : la sortie part dans un pipe.
- **`strip_prefixes()`** : retire `sudo`, `env`, `timeout 5`, `nice -n 10`,
  `FOO=1`… pour trouver la vraie commande.
- **`parse_bounds()`** : interprète les options de `head`/`tail` :
  - sans option, 10 lignes ;
  - `-n N`, `-N` et `--lines=N` bornent à N ;
  - `-c` (octets) est considéré comme minuscule ;
  - `tail -n +K` part de la ligne K ;
  - `head -n -N` (« tout sauf les N dernières ») n'est pas borné ;
  - `-f` (follow) n'est jamais bloqué.

  Pour `cat` et consorts, tout mot commençant par un tiret est une option.
- **`through_pipe()`** : suit la sortie d'un lecteur le long du pipeline :
  - un **filtre** (`grep`, `wc`, `sort`…) : le fichier n'atteint pas le modèle,
    autorisé ;
  - une **copie** (`cat`, `less`, `tee`) : le fichier passe tel quel, donc on
    continue à le vérifier ;
  - `head`/`tail` : réduisent la borne.
- **`main()`** : parcourt **tous** les segments, suit les `cd`, ignore globs et
  variables (`unresolvable_arg`, pas de glob dans un hook), et renvoie
  `{"verdict":"check","files":[…]}` ou `{"verdict":"allow","reason":…}`.

### Ce qui a été retiré

Avant la simplification, un troisième hook, `SubagentStop`
(`hooks/subagent-stop.sh`), relisait le transcript de chaque worker pour en
mesurer le coût, avec une agrégation dédiée (`hooks/lib/usage.jq`) et une
attente de fin d'écriture. Il a été supprimé : le coût est désormais mesuré
par A/B. Deux pièges du format des transcripts, découverts à cette occasion,
restent bons à connaître :

- Claude Code écrit une ligne par *bloc de contenu* et y répète l'usage du
  message ; `output_tokens` croît d'un bloc à l'autre. Sommer les lignes
  surcompte, prendre la première sous-compte.
- `SubagentStop` se déclenche avant que le dernier message du worker soit
  écrit sur disque.

---

## 4. Les agents (`agents/*.md`)

Ce sont des fichiers Markdown dont le frontmatter définit l'agent (nom,
description, outils, modèle, nombre de tours) et dont le corps est le system
prompt.

- **`bulk-reader.md`** : Haiku 4.5, outils `Read, Grep, Glob`, 6 tours au
  maximum. Le prompt impose :
  - de répondre **à la question posée**, pas de résumer tout le fichier ;
  - de s'arrêter vite, parce que chaque tour renvoie tout son contexte ;
  - des puces avec des ancres `path:line` et les signatures citées mot pour mot ;
  - deux sections obligatoires. `NOT COVERED` existe parce que le parent ne
    peut pas savoir ce que le worker a omis. `VERIFY BEFORE EDIT` liste les
    plages à relire avant d'éditer.
- **`code-writer.md`** : Haiku, outils `Read, Grep, Glob, Write`, 8 tours. On
  lui donne une spec, un fichier de référence et une cible ; il écrit la cible
  sur disque et renvoie au plus 10 lignes
  (`WROTE / CONTAINS / ASSUMED / NEEDS REVIEW`), **jamais** le code. Il
  économise sur les tokens de **sortie**, cinq fois plus chers que ceux
  d'entrée.

  Le README insiste : **aucun hook ne peut forcer cette délégation**. Quand
  `PreToolUse:Write` se déclenche, le contenu est déjà généré, donc déjà payé.
  L'usage de `code-writer` repose sur le bon vouloir du modèle ; savoir s'il
  rapporte est, là encore, une question d'A/B.

## 5. `bin/haiku-shunt`, la CLI (Python)

Elle lit la config et retrouve le répertoire de logs avec la même cascade que
`common.sh`. Elle ne calcule plus aucune économie : deux sous-commandes.

- **`report`** : ne fait que compter, à partir des événements `hook_decision`.
  - table DECISIONS : pour chaque hook, nombre d'appels, de refus, latences
    p50/p95 ;
  - table WHY : les `reason_code` les plus fréquents. `deny_cap_reached` y
    signale un gros fichier passé quand même après des relances ;
  - DENIED SIZES : histogramme des refus par nombre de lignes qui auraient
    atteint le modèle (`effective_lines` pour Bash, `lines` pour Read ; tranches
    `<350`, `350-500`, `500-1000`, `1000-2000`, `2000+`). Un changement de seuil
    ne touche que les refus des tranches qu'il traverse. Le seuil affiché est
    celui loggé par le hook (`threshold_lines`), donc surcharges comprises.
  - `--format json` : `hook_calls`, `denies`, `reasons`, `deny_size_buckets` ;
    c'est ce que `bench/ab.sh` lit pour compter les refus.
- **`doctor`** : vérifie `jq`, `python3`, `flock`, le répertoire de logs (avec
  un avertissement sur NFS) et les droits d'exécution des hooks. Il affiche
  ensuite le **point mort** :
  - `parent_factor` = `2 + μ·R`, avec `μ = 0.10·h + 1.0·(1−h)` (le `2` est
    l'écriture de cache d'une heure de la session principale) ;
  - `breakeven_tokens` =
    `(floor·1.25·Haiku_in + 500·Haiku_out) / (P_in·facteur − 1.25·Haiku_in)`,
    où `floor` est le coût fixe du worker (14 600 tokens, dans la config). Le
    terme `−1.25·Haiku_in` vient de ce que le worker doit lui-même mettre le
    fichier en cache.
  
  Le `1.25` est l'écriture de cache de 5 minutes du worker. Avec R=12 et
  h=0.9 : ~1 030 tokens (~79 lignes) pour Opus, ~2 839 (~218 lignes) pour
  Sonnet. C'est un ordre de grandeur, pas une mesure.
  
  Enfin, il signale ce qui demande une délégation réelle : la forme sous
  laquelle `agent_type` arrive au hook, et le modèle réel du worker (à lire
  dans `message.model` de son transcript ; une entrée Haiku dans `modelUsage`
  ne prouve rien, Claude Code fait son propre petit appel Haiku à chaque
  session).

## 6. Les skills

- **`skills/shunt-report/SKILL.md`** : `/haiku-shunt:shunt-report`. Le bloc
  ` ```! ` exécute `haiku-shunt report $ARGUMENTS` au chargement du skill, puis
  indique au modèle comment présenter le résultat : taux de refus, `deny_cap_reached`,
  lecture des tranches de taille, et surtout ne pas présenter ce rapport comme
  une économie (renvoi vers `bench/ab.sh`).
- **`skills/shunt-doctor/SKILL.md`** : même principe avec `doctor`, plus les
  deux vérifications qui demandent une délégation réelle.

---

## 7. Tests : `evals/` et `tests/`

Tout tourne **hors ligne**, sans Claude Code ni appel API.

### `evals/run.sh`

Le runner de cas déclaratifs. Chaque cas JSON contient :

- `input` : le payload du hook, avec des placeholders `@FIX@` / `@FIX:id@` ;
- `fixtures` : des fichiers générés à la volée, selon un mode (`seq`, `tiny`
  pour beaucoup de lignes et peu d'octets, `nonewline`, `minified`, `binary`,
  `symlink`, `dangling`, `unreadable`, `dir`…) ;
- `env` : des surcharges d'environnement ;
- `expect` : la décision (`deny`/`none`), le `reason_code` lu dans le log, une
  regex sur le message, une latence maximale.

Les fixtures sont recréées à chaque cas. Le runner exécute ensuite chaque
`tests/*.sh` et compte les lignes `ok`/`FAIL`.

### Les fichiers de cas

- **`evals/cases/read-hook.json`** (35 cas) : seuils, plancher en octets,
  fichiers minifiés, `offset`/`limit`, binaires, liens symboliques, fichiers
  illisibles, off-by-one sur la dernière ligne.
- **`evals/cases/bash-hook.json`** (87 cas) : les cas limites du parseur
  (`head -n`, `tail -n +K`, `2>/dev/null`, `cd`, pipes, heredocs, préfixes,
  quotes…).
- **`evals/cases/recursion.json`** (14 cas) : la garde anti-récursion. Il couvre
  les formes namespacées, `agent_type` à `null` ou vide (traité comme le thread
  principal), et un sosie comme `not-bulk-reader`, qui ne doit **pas** être
  exempté.

### Les tests unitaires

- **`tests/breakeven.sh`** : `parent_factor` et `breakeven_tokens` comparés à
  des valeurs calculées à la main (4 368 pour Sonnet à R=10, h=1 ; 1 030 pour
  Opus aux valeurs par défaut ; 27 667 pour un parent Haiku à R=0), et vérifie
  que `doctor` affiche le même chiffre.
- **`tests/report.sh`** : log synthétique → nombre d'appels, de refus, raisons
  et tranches de taille (y compris un refus Bash compté sur ses lignes
  effectives et un refus sur la seule taille en octets) ; log vide → exit 0.
- **`tests/deny_cap.sh`** : le disjoncteur. Refus, refus, puis passage ;
  compteur par chemin et par session ; 20 refus concurrents qui laissent le
  fichier d'état intact.
- **`tests/robustness.sh`** : fail-open sur des entrées invalides, une
  commande énorme, et 200 écritures de log concurrentes sans ligne corrompue.

## 8. Benchmark : `bench/`

- **`bench/ab.sh`** : la seule mesure de coût du repo. Il lance la même tâche
  dans plusieurs bras :
  - `off`, toujours présent : pas de plugin du tout (ou plugin désactivé avec
    `--control disable`) ;
  - `on` par défaut (plugin avec ses réglages), ou un bras par
    `--arm NOM:VAR=VAL[,VAR=VAL]`, par exemple
    `--arm min200:SHUNT_MIN_LINES=200 --arm min800:SHUNT_MIN_LINES=800`.

  Les bras sont **entrelacés**, dans un ordre qui tourne à chaque répétition,
  pour ne pas confondre l'effet du plugin avec la dérive du cache ou de la
  charge serveur. Chaque run :
  - s'exécute en `claude -p --output-format json` avec un `--session-id` neuf
    et son propre répertoire de logs ;
  - est chiffré par Claude Code lui-même : `total_cost_usd`, `num_turns`, et la
    part Haiku tirée de `modelUsage` (sous-agents inclus, plus ~0,001 $ d'appel
    Haiku que Claude Code fait de lui-même, y compris dans le bras `off`) ;
  - compte les refus (via `report --format json`) et les délégations (les
    `agent-*.meta.json` du dossier `subagents/` de la session) ;
  - passe par `task_verify`, parce qu'un bras moins cher qui n'a pas fait le
    travail n'a rien économisé.

  Le résumé donne les **médianes** par bras et l'écart de chaque bras avec
  `off`. Il refuse de démarrer sur un repo sale, car il lance `git clean -fd`
  entre les runs, et force `LC_ALL=C` pour éviter qu'une virgule décimale
  décale les colonnes du CSV.

  Le chiffre de Claude Code est plus juste qu'un calcul maison : il facture
  les écritures de cache à la durée de vie réellement utilisée (1 heure = 2×
  le tarif d'entrée). Au smoke test, l'ancien calcul maison à 1,25× sous-estimait
  le coût d'environ un tiers.
- **`bench/tasks/smoke.sh`** : génère un repo jetable (`service.py`, 60
  classes) avec une question courte. C'est un test de câblage, **pas** une
  mesure : avec `R` proche de 0, le plugin perd forcément.
- **`bench/tasks/TEMPLATE.sh`** : modèle de vraie tâche. La règle d'or : une
  tâche longue, multi-tours, qui lit les gros fichiers **tôt**.

**Régler le seuil** : partir du point mort de `doctor`, regarder les tranches
de `report` pour voir quelles valeurs changeraient quelque chose, puis comparer
2 ou 3 valeurs très espacées par A/B. Un réglage fin (350 contre 450) est noyé
dans le bruit : deux sessions identiques varient facilement de 20 à 40 %.

## 9. Historique : `HARNESS_ANALYSIS.md` et la simplification

`HARNESS_ANALYSIS.md` (non suivi par Git) est une revue de code qui relevait 4
problèmes, corrigés dans le commit « Fix the four HARNESS_ANALYSIS findings » :

1. le parseur Bash s'arrêtait au premier lecteur rencontré ;
2. `R` comptait des lignes de transcript au lieu de messages ;
3. l'overhead du message de refus était compté par délégation au lieu de par
   refus ;
4. `subagent-stop.sh` plantait sur `[]`.

La simplification qui a suivi a retiré le code concerné par les points 2, 3 et
4 (modèle de coût de `report`, `analyze`, `session-cost`, `SubagentStop`). Seul
le point 1 reste pertinent pour le code actuel.

---

## 10. Les points subtils à retenir

1. **Fail-open partout** : pas de `set -e`, un `trap ERR`, `exit 0` sur tous les
   chemins. Autoriser, c'est ne rien émettre.
2. **Trois protections contre le deadlock** :
   - `agent_type`, comparé sans son namespace ;
   - l'option d'exempter les autres agents ;
   - le disjoncteur par chemin et par session, qui garantit l'absence de boucle
     même si Claude Code cessait d'envoyer `agent_type`.
3. **Le coût se mesure par A/B, pas par modèle** : le plugin compte ce que
   font ses hooks ; ce qu'ils font économiser vient uniquement de la
   comparaison avec/sans plugin, chiffrée par Claude Code.
4. **Le point mort est un ordre de grandeur** : une formule avec `R` et `h`
   supposés, utile pour choisir les valeurs de seuil à tester, pas pour
   conclure.
5. **Limites assumées** (section « Known limits » du README) :
   - après un refus, le modèle peut lire tout le fichier par fenêtres au lieu
     de déléguer. C'était systématique avec l'ancien message ; depuis sa
     correction, le premier smoke test a délégué spontanément, mais un seul
     run ne prouve rien ;
   - `bash -c "cat …"`, `sed`, `awk` et `python -c` ne sont pas interceptés ;
   - les tokens loggés sont estimés à chars/4, à ±15 % près ; ils ne servent
     qu'aux tranches de taille.
