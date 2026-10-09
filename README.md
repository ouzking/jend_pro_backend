# JËND PRO — Backend

Backend du SaaS **JËND PRO** (gestion intelligente pour commerces et PME — Sénégal,
puis Afrique de l'Ouest), construit sur **Supabase** (PostgreSQL, Auth, RLS, Storage,
Realtime, Edge Functions).

- Projet Supabase cible : **`jend_pro`** (ref `lmyhrksehcodyylzphyn`, région `eu-west-1`, PostgreSQL 17)
- Dépôt : https://github.com/ouzking/jend_pro_backend

## Documentation

| Document | Contenu |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Architecture, multi-tenancy, conventions, décisions |
| [docs/database.md](docs/database.md) | Modèle de données, tables, relations, plan des migrations |
| [docs/security.md](docs/security.md) | RLS, helpers, Storage, Auth, secrets, tests de sécurité |
| [docs/roles-and-permissions.md](docs/roles-and-permissions.md) | RBAC : rôles, permissions, matrice |
| [docs/business-rules.md](docs/business-rules.md) | Règles métier, stratégie financière XOF, stock, ventes, crédit |
| [docs/migration-to-laravel.md](docs/migration-to-laravel.md) | Évolution vers Laravel (V2) |
| [docs/frontend-integration.md](docs/frontend-integration.md) | **Guide Flutter / React** : connexion, onboarding, permissions, catalogue, images, erreurs |
| [types/database.types.ts](types/database.types.ts) | Types TypeScript générés (schéma `public`) |

## Prérequis

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (démarré) — pour Supabase local
- Node.js ≥ 20 (la CLI est utilisée via `npx supabase`)
- [Deno](https://deno.com/) ≥ 2 — pour développer/tester les Edge Functions

## Démarrage local

```bash
npx supabase start          # démarre la stack locale (Postgres, Auth, Storage…)
npx supabase db reset       # applique toutes les migrations + seed
npx supabase test db        # exécute les tests pgTAP
```

Ports locaux (décalés en 544xx pour cohabiter avec d'autres projets Supabase locaux) :
API `http://127.0.0.1:54421`, base `postgresql://postgres:postgres@127.0.0.1:54422/postgres`,
Studio `http://127.0.0.1:54423`, e-mails de test (Mailpit) `http://127.0.0.1:54424`.

Comptes de démonstration créés par `supabase/seed.sql` (local uniquement, mot de passe
`jendpro-demo`) pour « Boutique Démo Dakar » : `owner@demo.jendpro.local` (OWNER),
`cashier@demo.jendpro.local` (CASHIER), `stock@demo.jendpro.local` (STOCK_MANAGER).
Back-office : `admin@demo.jendpro.local` (SUPER_ADMIN) et `support@demo.jendpro.local` (SUPPORT).
Données de démo réalistes : 8 produits en 3 catégories, un fournisseur et un achat
réceptionné, 3 clients (dont une dette reprise du cahier), 3 ventes (espèces, Wave, crédit),
un règlement Orange Money et 2 dépenses — toutes créées via les vraies RPC.

## Tests

Les tests pgTAP sont dans `supabase/tests/database/` et s'exécutent dans l'ordre
alphabétique :

- `00000_test_helpers.sql` installe le schéma `tests` (**base locale uniquement**,
  jamais dans une migration) : `tests.create_user`, `tests.get_user_id`,
  `tests.authenticate_as`, `tests.authenticate_as_anon`, `tests.clear_authentication`.
  Il fournit aussi la fixture `tests.setup_two_tenants()` (entreprise A avec chaque rôle,
  entreprise B, un utilisateur membre des deux, un utilisateur sans entreprise).
- `00100_foundation.test.sql` vérifie les invariants globaux, réévalués à chaque
  exécution : RLS activée sur toutes les tables, aucun droit pour `anon`, `search_path`
  fixé sur toute fonction `SECURITY DEFINER`.
- `00200` profils · `00300` création d'entreprise et matrice RBAC · `00400` **isolation
  inter-tenant** · `00500` cycle de vie des membres et anti-escalade · `00600` catalogue
  (catégories, produits, masquage des coûts) · `00610` policies Storage · `00700` inventaire
  (règles de stock, atomicité, invariant stock = Σ mouvements) · `00800` clients, crédit et
  règlements (plafonds, atomicité, invariant solde = Σ transactions) · `00900` achats
  (cycle, réception, coût moyen pondéré, paiements fournisseurs) · `01000` ventes (atomicité,
  idempotence, crédit, remises, annulation, visibilité caissier, invariants) · `01100` dépenses,
  employés et bucket privé `documents` · `01200` abonnements (limites, mode restreint, grâce) ·
  `01300` notifications (événements, destinataires, accès, publication Realtime) · `01400` audit
  (couverture, rôle de l'acteur, immuabilité, journal paginé) · `01500` plateforme (activation
  idempotente, tâche quotidienne) · `01600` analytics (chiffres calculés à la main) ·
  `01700` **garde-fous d'architecture** (surface API et tables modifiables figées, conventions) ·
`01800` back-office (RBAC plateforme, lectures inter-entreprises, suspension, paiement manuel,
analytics, audit, gestion du staff) · `01900` support et annonces · `02000` double
authentification du staff.

**Total : 674 tests pgTAP + 20 tests Deno**, exécutés en CI à chaque push
(`.github/workflows/ci.yml`).

Chaque fichier de test s'exécute dans une transaction annulée (`rollback`) : aucun effet
de bord entre les tests.

Edge Functions (Deno, via `npx deno`) :

```bash
cp supabase/functions/.env.example supabase/functions/.env   # puis mettre un secret local
bash scripts/test-functions.sh   # tests unitaires + fonctions servies localement + intégration
```

## Lier au projet distant `jend_pro`

```bash
npx supabase login
npx supabase link --project-ref lmyhrksehcodyylzphyn
npx supabase db push                             # applique les migrations versionnées
```

Vérifications après chaque déploiement :

```bash
npx supabase migration list            # local et distant alignés
npx supabase db diff --linked --schema public,private   # doit afficher "No schema changes found"
npx supabase db lint --linked --schema public,private
```

**État de la production** (2026-10-07) : migrations des Phases 2 à 15 appliquées (17 migrations) ; Edge Functions
`invite-member` et `billing-webhook` déployées (`BILLING_WEBHOOK_SECRET` à définir avant usage). Contrôles
passés : schéma identique aux migrations, linter propre, `anon` refusé sur tables et RPC,
schéma `private` non exposé. Le seed de démo n'est **jamais** envoyé en production.

> Ne jamais modifier le schéma via le Dashboard. Toute évolution passe par
> `npx supabase migration new <nom>`.

## Secrets

Aucun secret dans Git. La clé `service_role` n'est utilisée **que** dans les Edge
Functions (`npx supabase secrets set ...`), jamais dans Flutter ou React.

## Feuille de route

Chaque phase suit : analyser → planifier → implémenter → tester → vérifier → documenter.
Les tables sont livrées **avec** leur RLS et leurs tests dans la même phase.

| Phase | Périmètre | Statut |
|---|---|---|
| 1 | Architecture, conventions, documentation | ✅ Terminée |
| 2 | Fondations : `supabase init`, schéma `private`, privilèges par défaut, utilitaires, harnais de tests pgTAP | ✅ Terminée |
| 3 | Auth, `profiles`, `businesses`, `locations`, `business_members`, `create_business` | ✅ Terminée |
| 4 | RBAC (`roles`, `permissions`, `role_permissions`), helpers RLS, `audit_logs`, tests d'isolation | ✅ Terminée |
| 5 | Catégories, produits, coûts, Storage images | ✅ Terminée |
| 6 | Inventaire, mouvements, ajustements, inventaire physique, transferts, stock faible | ✅ Terminée |
| 7 | Clients, compte client, crédits, règlements, socle des paiements | ✅ Terminée |
| 8 | Fournisseurs, achats, réception (CMP), paiements fournisseurs | ✅ Terminée |
| 9 | Ventes (caisse atomique et idempotente), paiements multiples, crédit, annulation | ✅ Terminée |
| 10 | Dépenses (audit complet, justificatifs privés), employés | ✅ Terminée |
| 11 | Abonnements, essai, limites des plans, mode restreint (lecture seule + caisse) | ✅ Terminée |
| 12 | Notifications (stock faible, vente importante, invitation, abonnement), Realtime | ✅ Terminée |
| 13 | Audit complet et immuable, rôle de l'acteur, journal paginé | ✅ Terminée |
| 14 | Edge Functions (`invite-member`, `billing-webhook`), activation idempotente des abonnements, tâche quotidienne `pg_cron` | ✅ Terminée |
| 15 | Analytics (tableau de bord), garde-fous d'architecture, revue des index, seed de démo, CI | ✅ Terminée |
| 16 | Back-office plateforme : RBAC staff, RPC `admin_*`, support (tickets), annonces, paiements manuels, indicateurs SaaS | ✅ Terminée |
| 17 | Double authentification du staff (TOTP, aal2 exigé en base) | ✅ Terminée |

## Configuration manuelle Supabase (Dashboard)

Liste tenue à jour au fil des phases :

- _(Phase 3)_ Auth : URL du site et URLs de redirection, templates e-mail, fournisseur SMS (OTP téléphone).
- _(Phase 14)_ Secrets Edge Functions : `BILLING_WEBHOOK_SECRET`, `SITE_URL` (voir docs/security.md §7).
- _(Phase 14)_ `pg_cron` est activé par migration ; vérifier le job dans Dashboard → Integrations → Cron.
