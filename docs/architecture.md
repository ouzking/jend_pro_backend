# Architecture — JËND PRO Backend (V1)

> Statut : **Phase 1 — validée comme cible**. Toute déviation ultérieure doit être
> documentée ici (section « Journal des décisions »).

## 1. Vue d'ensemble

JËND PRO est un SaaS multi-tenant de gestion pour commerces et PME (Sénégal, puis
Afrique de l'Ouest). En V1, **Supabase est l'unique backend** :

```text
 Flutter (mobile)        React (web / back-office)
        │                         │
        └──────────┬──────────────┘
                   │  HTTPS + JWT (anon key + session utilisateur)
                   ▼
 ┌──────────────────────────────────────────────────────────────┐
 │                         Supabase                              │
 │                                                               │
 │  Auth ── JWT ──► PostgREST ──► PostgreSQL (RLS partout)       │
 │                    │              │                           │
 │                    │              ├─ schema public  (tables + │
 │                    │              │   RPC métier exposées)    │
 │                    │              └─ schema private (helpers  │
 │                    │                  sécurité, non exposé)   │
 │  Storage (policies par business_id)                           │
 │  Realtime (notifications, événements de stock ciblés)         │
 │  Edge Functions (Deno) : webhooks paiement, intégrations,     │
 │                          tâches serveur, secrets              │
 └──────────────────────────────────────────────────────────────┘
```

Principes directeurs, par ordre de priorité :

1. **Sécurité et isolation des tenants** garanties par PostgreSQL (RLS), jamais par le client.
2. **Intégrité des données** : contraintes SQL, clés étrangères composites, opérations atomiques.
3. **Logique métier centralisée côté base** (fonctions SQL) et documentée, pour éviter
   qu'elle se disperse dans Flutter/React et pour faciliter la migration Laravel (V2).
4. **Simplicité** : pas de technologie ni de table sans justification.

## 2. Répartition des responsabilités

| Couche | Rôle | Ne fait PAS |
|---|---|---|
| Flutter / React | UI, saisie, cache local, appel de l'API | Sécurité, calculs financiers de référence, décrément de stock |
| PostgREST (lecture/CRUD simple) | Lecture paginée, CRUD des entités simples (catégories, clients, fournisseurs…) protégé par RLS | Opérations multi-tables |
| **RPC SQL (`public.*` fonctions)** | Opérations métier atomiques : vente, annulation, achat/réception, ajustement de stock, règlement de crédit, invitation membre | Appels réseau externes |
| Triggers | Invariants techniques : `updated_at`, audit automatique, limites d'abonnement, protection du dernier OWNER | Logique métier complexe (préférer les RPC explicites) |
| Edge Functions | Secrets, webhooks (Wave, Orange Money…), e-mails/SMS, génération PDF, IA future | Contourner les RPC métier (elles les appellent) |
| Storage | Fichiers (logos, images produits, justificatifs, factures) | — |
| Realtime | Push d'événements à valeur forte (notifications, stock faible) | Diffusion de toutes les tables |

**Règle clé** : toute opération qui modifie plus d'une table de manière couplée
(ex. vente → lignes → stock → mouvements → paiement → audit) est une **fonction SQL
unique exécutée dans une seule transaction**. Le client n'orchestre jamais ces étapes.

## 3. Schémas PostgreSQL

| Schéma | Exposé via API ? | Contenu |
|---|---|---|
| `public` | Oui | Tables métier (toutes avec RLS), vues `security_invoker`, RPC métier appelables par `authenticated` |
| `private` | **Non** | Fonctions helpers `SECURITY DEFINER` (vérification d'appartenance/permissions), fonctions internes de stock, triggers |
| `auth`, `storage` | Géré par Supabase | Identité, fichiers |

Les helpers de sécurité sont `SECURITY DEFINER` + `SET search_path = ''` et vivent dans
`private` pour ne jamais être appelables directement via PostgREST.

Les RPC métier publiques sont `SECURITY DEFINER` uniquement lorsqu'elles doivent écrire
dans des tables non modifiables directement par le client (ex. `inventory`,
`inventory_movements`, `audit_logs`). Elles commencent **toujours** par une vérification
explicite : `private.require_permission(p_business_id, '<permission>')`.

## 4. Stratégie multi-tenant

- **Modèle** : base partagée, schéma partagé, colonne `business_id` sur chaque table
  métier (« pool model »). C'est le modèle adapté à des milliers de petites entreprises.
- **Appartenance** : `business_members (business_id, user_id, role_id, status)`.
  Un utilisateur peut appartenir à **plusieurs** entreprises ; aucune hypothèse
  « 1 utilisateur = 1 entreprise ».
- **Contexte actif** : le client envoie explicitement le `business_id` (filtres et
  paramètres RPC). La RLS vérifie l'appartenance à chaque requête. Pas de
  « business courant » stocké dans le JWT en V1 (évite les JWT périmés après
  changement de rôle).
- **Intégrité inter-tenant par clés étrangères composites** : chaque table tenant
  expose `UNIQUE (business_id, id)` et les tables enfants référencent
  `(business_id, <parent>_id)`. Il devient **physiquement impossible** de lier une
  ligne de vente de l'entreprise A à un produit de l'entreprise B, même en cas de bug
  dans une fonction `SECURITY DEFINER`.
- **Default deny**, en deux couches :
  1. **Privilèges** : aucun droit implicite pour `anon`/`authenticated` sur les tables et
     fonctions (default privileges révoqués dans la migration `foundation`). Chaque table
     accorde explicitement les opérations — et si besoin les colonnes — autorisées.
  2. **RLS** activée sur toutes les tables `public` ; aucune policy = aucun accès.
  La RLS n'est pas `FORCE` : les fonctions `SECURITY DEFINER` (propriétaire `postgres`)
  doivent pouvoir écrire dans les tables internes ; leur sécurité repose sur la
  vérification explicite de permission (voir [security.md §4](security.md#4-rpc-security-definer--checklist-obligatoire)).

Détails : [security.md](security.md).

## 5. Données de référence vs données tenant

| Type | Exemples | `business_id` | Écriture |
|---|---|---|---|
| Globales | `permissions`, `subscription_plans`, rôles système | NULL / absent | Migrations / service_role uniquement |
| Tenant | produits, ventes, clients… | NOT NULL | Membres autorisés (RLS + RPC) |
| Utilisateur | `profiles`, notifications personnelles | via `user_id` | Propriétaire de la ligne |

## 6. Organisation du dépôt

```text
jend_pro_backend/
├── supabase/
│   ├── config.toml            # généré par `supabase init` (Phase 2)
│   ├── migrations/            # SQL versionné, ordonné, jamais réécrit une fois appliqué
│   ├── functions/             # Edge Functions Deno (une fonction = un dossier)
│   │   └── _shared/           # code partagé (client Supabase, erreurs, CORS)
│   ├── seed.sql               # données de dev locales uniquement (jamais en prod)
│   └── tests/
│       └── database/          # tests pgTAP (`supabase test db`)
├── docs/
│   ├── architecture.md        # ce document
│   ├── database.md            # modèle de données
│   ├── security.md            # RLS, Storage, secrets
│   ├── roles-and-permissions.md
│   ├── business-rules.md      # règles métier + stratégie financière
│   └── migration-to-laravel.md
└── README.md
```

> Note : la CLI Supabase attend `supabase/seed.sql` (configurable via
> `[db.seed].sql_paths`). On utilisera `supabase/seed.sql` ou `supabase/seed/*.sql`
> déclaré dans `config.toml` — décision prise en Phase 2.

## 6 bis. Edge Functions et tâches planifiées (Phase 14)

| Fonction | Auth | Rôle | Pourquoi une Edge Function |
|---|---|---|---|
| `invite-member` | JWT utilisateur (`verify_jwt = true`) | Inviter une personne **sans compte** : vérifie `members.manage`, crée le compte (API admin Auth), puis appelle `invite_member` **en tant qu'appelant** | L'API admin Auth exige la clé `service_role` (secret serveur) |
| `billing-webhook` | Signature HMAC (`verify_jwt = false`) | Confirmation de paiement d'abonnement, indépendante du fournisseur → `platform_activate_subscription` | Appelé par un tiers ; secret partagé ; clé `service_role` |

Code partagé : `supabase/functions/_shared/` (`http.ts` CORS + mapping des erreurs SQL → HTTP,
`clients.ts` client « appelant » vs client admin, `signature.ts`, `validation.ts`).
Principe : une Edge Function **n'est jamais un raccourci autour des règles** ; elle utilise le
client de l'appelant pour toute opération métier et ne recourt à `service_role` que pour ce
qui l'exige (API admin, RPC `platform_*`).

Tâches planifiées : **`pg_cron`** en base (plus simple et plus fiable qu'une Edge Function
planifiée pour du SQL) — `jendpro-daily-maintenance` à 06:00 UTC (= Dakar) : rappel de fin
d'essai (J-3, une fois), passage en `EXPIRED` des abonnements échus (notifie les
propriétaires), purge des notifications (lues > 90 j, toutes > 180 j).

Évolutions prévues (non construites tant que le besoin n'est pas confirmé) : adaptateurs Wave /
Orange Money vers `billing-webhook`, génération de factures PDF (bucket `invoices`), envoi SMS,
résumé quotidien / IA.

## 6 ter. Qualité, garde-fous et CI (Phase 15)

- **Tests** : 564 tests pgTAP (19 fichiers) + 20 tests Deno (Edge Functions). Les suites
  d'isolation ont été **validées par mutation** (failles injectées volontairement → échec).
- **Garde-fous d'architecture** (`01700_hardening.test.sql`) : types d'argent, `timestamptz`,
  clés primaires, `search_path` de toutes les fonctions, propriétaire des `SECURITY DEFINER`,
  **surface RPC figée**, **tables modifiables par les clients figées**, liste revue des RPC
  `SECURITY DEFINER` sans `require_permission`, policies SELECT présentes, index `business_id`,
  vues `security_invoker`, buckets publics, publication Realtime. Toute évolution de la surface
  de sécurité impose une modification consciente de ce test (revue).
- **Invariants comptables** testés : stock = Σ mouvements, solde client = Σ transactions,
  sous-total = Σ lignes, payé = Σ paiements `IN`.
- **CI** : `.github/workflows/ci.yml` reconstruit la base depuis les migrations (+ seed de démo
  qui rejoue achats, ventes et crédit via les RPC), lance pgTAP, le lint SQL et les tests des
  Edge Functions à chaque push / pull request.

## 7. Conventions

### 7.1 Nommage SQL
- Tables : `snake_case`, **pluriel** (`products`, `sale_items`).
- Colonnes : `snake_case` ; FK = `<entité_singulier>_id` (`product_id`).
- Clé primaire : `id uuid DEFAULT gen_random_uuid()`.
- Horodatage : `created_at timestamptz NOT NULL DEFAULT now()`,
  `updated_at timestamptz NOT NULL DEFAULT now()` (trigger `private.set_updated_at`).
- Auteur : `created_by uuid REFERENCES auth.users(id)` lorsque pertinent
  (valeur imposée côté serveur via `auth.uid()`, jamais fournie par le client).
- Montants : `bigint` en unités entières de la devise (XOF = francs entiers),
  suffixe explicite si ambigu (`unit_price`, `total_amount`). **Jamais de float.**
- Quantités : `numeric(14,3)` (vente au kilo/litre possible).
- Contraintes nommées : `<table>_<colonne>_check`, `<table>_<cols>_key`, `<table>_<col>_fkey`.
  **Attention** : PostgreSQL nomme déjà `<table>_<colonne>_check` les CHECK déclarés sur la
  colonne ; une contrainte de table explicite sur la même colonne doit avoir un suffixe
  distinct (`_scope_check`, `_required_check`, `_sign_check`…).
- Index : `<table>_<cols>_idx`.
- Policies RLS : phrase lisible, ex. `"members with products.read can select"`.
- Fonctions RPC : verbe + objet (`create_sale`, `cancel_sale`, `adjust_stock`).
  Paramètres préfixés `p_`, variables `v_`.

### 7.2 Types énumérés
- Ensembles **fermés et stables** (statut de vente, type de mouvement, méthode de
  paiement) : **ENUM PostgreSQL** → types générés propres pour Flutter/TypeScript.
- Ensembles **configurables par le métier** (catégories de dépenses, unités) : **table**.
- Ajout de valeur à un ENUM = nouvelle migration `ALTER TYPE ... ADD VALUE`.
  Retrait de valeur interdit (on déprécie).

### 7.3 Migrations
- Nom : `YYYYMMDDHHMMSS_<domaine>_<description>.sql` (généré par `supabase migration new`).
- Une migration = un sujet cohérent. Chaque migration crée tables **+ RLS + policies
  + index + grants** ensemble : **aucune table n'existe jamais sans RLS**.
- Une migration appliquée (local partagé, staging ou prod) n'est **jamais modifiée** :
  on ajoute une nouvelle migration.
- Idempotence quand c'est sûr (`CREATE EXTENSION IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`) ;
  pas de `IF NOT EXISTS` sur les tables (masquerait une dérive de schéma).
- Pas de modification de schéma via le Dashboard. Si une dérive est détectée :
  `supabase db diff` → nouvelle migration.

### 7.4 Suppression
- Entités référencées par de l'historique (produits, clients, fournisseurs) :
  **archivage** (`status = 'ARCHIVED'` / `archived_at`), pas de `DELETE`.
- Écritures financières et mouvements (ventes, paiements, mouvements de stock,
  transactions client, audit) : **append-only** ; on corrige par une écriture inverse.
- FK par défaut `ON DELETE RESTRICT` ; `CASCADE` uniquement pour des enfants purs
  (ex. `role_permissions`) — chaque `CASCADE` est justifié en commentaire.

### 7.5 Pagination et API
- Pagination par **keyset** (`created_at, id`) pour les historiques volumineux
  (ventes, mouvements), `range()` acceptable pour les petites listes.
- Agrégations (dashboard, rapports) via RPC/vues SQL, jamais calculées côté client
  sur des listes complètes.

### 7.6 Fuseau horaire
- Stockage en `timestamptz` (UTC). `businesses.timezone` (défaut `Africa/Dakar`)
  utilisé pour les regroupements « par jour » des rapports.

## 8. Décisions d'architecture (ADR courtes)

| # | Décision | Justification |
|---|---|---|
| D1 | RLS + tables et RPC créées ensemble, domaine par domaine | Évite toute fenêtre où une table existe sans protection (le découpage « schéma complet puis RLS » est rejeté) |
| D2 | Montants en `bigint` (unités entières de devise) | XOF n'a pas de subdivision (ISO 4217 : 0 décimale) ; exact, rapide, pas d'erreur d'arrondi |
| D3 | Stock = cache `inventory` + grand livre `inventory_movements` append-only | Lecture rapide du stock courant + traçabilité complète ; écrit uniquement par fonctions |
| D4 | Notion d'emplacement (`locations`) dès la V1, une emplacement par défaut créé automatiquement | Les transferts (`TRANSFER`) et le multi-boutique sont très fréquents chez les PME ; ajouter la dimension plus tard imposerait une migration lourde du stock |
| D5 | FK composites `(business_id, id)` | Isolation des tenants garantie par le schéma, pas seulement par les policies |
| D6 | RBAC en tables (`roles`, `permissions`, `role_permissions`) avec rôles système | Évolutif (rôles personnalisés futurs) sans changer le code |
| D7 | Idempotence des ventes via `client_reference` (uuid fourni par le client) | Réseaux mobiles instables : un retry ne doit jamais créer deux ventes |
| D8 | Numérotation séquentielle par entreprise (`document_sequences`) | Numéros de ticket/facture lisibles et sans trou par entreprise |
| D9 | Pas de Laravel, Redis, file de messages en V1 | Supabase couvre le besoin ; à réévaluer en V2 |
| D10 | Abonnements modifiables uniquement par `service_role` (Edge Function / webhook) | Un client ne doit jamais pouvoir s'auto-attribuer un plan |

## 9. Journal des décisions

| Date | Décision | Auteur |
|---|---|---|
| 2026-10-07 | Architecture cible V1 (ce document) | Phase 1 |
| 2026-10-07 | **Coûts d'achat masqués** aux rôles sans `products.read_cost` (caissier). Mécanisme précis choisi en Phase 5 | Phase 2 |
| 2026-10-07 | **Abonnement expiré** : lecture seule, mais la caisse (ventes, règlements) reste ouverte | Phase 2 |
| 2026-10-07 | **Images produits et logos** en lecture publique (URL non devinable) ; justificatifs et factures privés | Phase 2 |
| 2026-10-07 | **Caissier** autorisé à vendre à crédit et à encaisser les règlements de crédit | Phase 2 |
| 2026-10-07 | **Privilèges explicites** : default privileges révoqués pour `anon`/`authenticated` ; RLS non forcée | Phase 2 |
| 2026-10-07 | Seed de dev : `supabase/seed.sql` (emplacement par défaut de la CLI) ; tests : `supabase/tests/database/*.sql` | Phase 2 |
| 2026-10-07 | Coûts isolés dans `product_costs` (RLS `products.read_cost`) plutôt que privilèges de colonnes | Phase 5 |
| 2026-10-07 | Colonnes « serveur » (`created_by`, `status`, `track_stock`) protégées par privilèges de colonnes : défaut `auth.uid()` + non accordées aux clients | Phase 5 |
| 2026-10-07 | `payments` créée dès la Phase 7 (socle générique), étendue par achats et ventes | Phase 7 |
| 2026-10-07 | `payment_status` en colonne **générée** (ne peut pas diverger des montants) | Phase 8 |
| 2026-10-07 | Coût figé des ventes isolé dans `sale_item_costs` (même règle que `product_costs`) | Phase 9 |
| 2026-10-07 | Mode restreint appliqué à un seul endroit (`businesses_with_permission` + `permissions.allowed_when_restricted`) | Phase 11 |
| 2026-10-08 | Realtime limité à `notifications` ; les événements métier passent par des notifications générées par triggers | Phase 12 |
| 2026-10-08 | Journal d'audit immuable pour tous les rôles (purge plateforme explicite uniquement) | Phase 13 |
| 2026-10-08 | Edge Functions limitées à ce qui exige un secret serveur ; tâches planifiées en `pg_cron` | Phase 14 |
| 2026-10-08 | Analytics en RPC SQL ; FK vers `auth.users` non indexées (revue documentée) ; garde-fous d'architecture en test | Phase 15 |
| 2026-10-09 | Back-office : RBAC plateforme séparé (`platform_admins`) + RPC `admin_*` en `SECURITY DEFINER` ; aucune policy ajoutée aux tables tenant ; jamais de `service_role` dans le navigateur | Phase 16 |
| 2026-10-10 | 2FA du staff appliquée en base via le claim `aal` (pas seulement dans l'interface) ; liste des permissions sensibles en données | Phase 17 |
| 2026-10-09 | Support (tickets, notes internes) et annonces plateforme livrés via les `notifications` `SYSTEM` existantes (pas de nouveau canal) | Phase 16 |
