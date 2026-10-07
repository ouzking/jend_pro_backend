# Migration vers Laravel (V2) — JËND PRO

> Laravel **n'est pas** introduit en V1. Ce document décrit comment la V1 est conçue
> pour permettre une migration progressive, sans réécriture « big bang ».

## 1. Cible

```text
V1                                   V2
Flutter ─┐                           Flutter ─┐
React  ──┼─► Supabase ─► PostgreSQL  React  ──┼─► Laravel API ─┬─► PostgreSQL (même base)
         │   (PostgREST, RPC, RLS)            │                ├─► Redis (cache, files)
                                              │                ├─► Queues (workers)
                                              └─► Supabase Auth / Storage (transition)
                                                               └─► Services externes
```

## 2. Ce qui rend la migration possible dès la V1

| Choix V1 | Bénéfice pour la V2 |
|---|---|
| Règles métier documentées dans `business-rules.md` | Spécification directement portable en services Laravel |
| Opérations critiques = **RPC SQL nommées** (`create_sale`, `receive_purchase`…) | Chaque RPC devient un service/Action Laravel avec la même signature ; on peut aussi les appeler depuis Laravel pendant la transition |
| Schéma relationnel classique (uuid, FK, `created_at/updated_at`, snake_case pluriel) | Compatible avec Eloquent sans adaptation |
| ENUM documentés | Mappés en PHP 8.1 `enum` |
| Montants en `bigint` | Pas de perte de précision (int PHP 64 bits) |
| Pas de logique métier dans Flutter/React | Les clients changent seulement d'URL/endpoint |
| Grands livres append-only (stock, crédit, paiements) | Logique reproductible et vérifiable lors de la bascule |
| `auth.users.id` (uuid) comme identité | Laravel peut valider les JWT Supabase pendant la transition |

## 3. Stratégie progressive (strangler pattern)

1. **Laravel en lecture seule** à côté de Supabase : rapports lourds, exports, analytics
   (connexion PostgreSQL avec un rôle dédié en lecture).
2. **Jobs asynchrones** : notifications, PDF, IA, webhooks paiement migrent des Edge
   Functions vers des queues Laravel.
3. **Opérations métier** une par une : le client appelle `POST /api/sales` (Laravel) au
   lieu de `rpc('create_sale')`. Laravel peut d'abord **appeler la fonction SQL
   existante** dans une transaction, puis la réécrire en PHP une fois couverte par des tests
   de parité.
4. **Auth** : Laravel valide les JWT Supabase (clé JWKS du projet) ; migration de l'Auth
   en dernier, seulement si nécessaire.
5. **Sécurité** : quand Laravel se connecte avec un rôle qui contourne la RLS, l'isolation
   tenant doit être appliquée dans Laravel (global scope `business_id` + policies). La RLS
   reste active pour les accès Supabase restants.

## 4. Candidats services Laravel (par priorité)

| Opération V1 | Service V2 | Raison |
|---|---|---|
| `create_sale`, `cancel_sale` | `SaleService` | Cœur métier, besoin de règles plus riches (promotions, fidélité) |
| `receive_purchase` | `PurchaseService` | Workflow (réception partielle, validation) |
| Stock (`apply_stock_movement`) | `InventoryService` | Multi-emplacement avancé, prévisions |
| Webhooks Wave / Orange Money | `PaymentGateway` + queues | Retry, idempotence, monitoring |
| Abonnements | `BillingService` | Facturation récurrente, relances |
| Rapports / analytics | `ReportingService` + cache Redis | Agrégations coûteuses |
| IA (résumé quotidien, prévisions) | Jobs planifiés | Traitements longs |

## 5. Points d'attention

- Les tests pgTAP de la V1 deviennent la **spécification de parité** pour la V2.
- Ne pas mélanger écritures Laravel et RPC Supabase sur une **même** opération pendant la
  transition (une seule source d'écriture par opération à un instant donné).
- Les triggers d'invariants (dernier OWNER, limites d'abonnement, `updated_at`) peuvent
  rester en base : ils protègent quelle que soit la couche applicative.
