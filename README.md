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
| 2 | Fondations : `supabase init`, schéma `private`, privilèges par défaut, utilitaires, harnais de tests pgTAP | ⏳ |
| 3 | Auth, `profiles`, `businesses`, `locations`, `business_members`, `create_business` | ⏳ |
| 4 | RBAC (`roles`, `permissions`, `role_permissions`), helpers RLS, `audit_logs`, tests d'isolation | ⏳ |
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
