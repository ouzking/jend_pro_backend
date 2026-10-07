# JËND PRO — Backend

Backend du SaaS **JËND PRO** (gestion intelligente pour commerces et PME — Sénégal,
puis Afrique de l'Ouest), construit sur **Supabase** (PostgreSQL, Auth, RLS, Storage,
Realtime, Edge Functions).

- Projet Supabase cible : **`jend_pro`**
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
`jendpro-demo`) : `owner@demo.jendpro.local` (OWNER) et `cashier@demo.jendpro.local`
(CASHIER) de « Boutique Démo Dakar ».

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
  inter-tenant** · `00500` cycle de vie des membres et anti-escalade.

Chaque fichier de test s'exécute dans une transaction annulée (`rollback`) : aucun effet
de bord entre les tests.

## Lier au projet distant `jend_pro`

```bash
npx supabase login
npx supabase link --project-ref <PROJECT_REF>   # ref visible dans l'URL du Dashboard
npx supabase db push                             # applique les migrations versionnées
```

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
| 5 | Catégories, produits, Storage images | ⏳ |
| 6 | Inventaire, mouvements, ajustements, transferts | ⏳ |
| 7 | Clients, compte client, crédits, règlements | ⏳ |
| 8 | Fournisseurs, achats, réception | ⏳ |
| 9 | Ventes, paiements, annulation (opérations atomiques) | ⏳ |
| 10 | Dépenses, employés | ⏳ |
| 11 | Abonnements, limites | ⏳ |
| 12 | Notifications, Realtime | ⏳ |
| 13 | Audit complet | ⏳ |
| 14 | Edge Functions (webhooks paiement, documents, notifications) | ⏳ |
| 15 | Tests transverses, hardening, performance, analytics | ⏳ |

## Configuration manuelle Supabase (Dashboard)

Liste tenue à jour au fil des phases :

- _(Phase 3)_ Auth : URL du site et URLs de redirection, templates e-mail, fournisseur SMS (OTP téléphone).
