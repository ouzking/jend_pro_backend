-- =============================================================================
-- JËND PRO — Expenses, employees, private documents bucket (Phase 10)
-- -----------------------------------------------------------------------------
-- * expense_categories: per-business list, defaults created automatically.
-- * expenses: CRUD through PostgREST (expenses.create / expenses.manage);
--   every insert / update / delete is audited with the full row.
--   Expenses are not payments: cash flow = payments IN - payments OUT - expenses.
-- * employees: HR record, distinct from the login account (optional link to a
--   business member). Archived, never deleted.
-- * documents bucket (PRIVATE): receipts under {business_id}/expenses/…,
--   downloaded through short-lived signed URLs.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- expense_categories
-- -----------------------------------------------------------------------------
create table public.expense_categories (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id),
  name        text not null check (char_length(btrim(name)) between 1 and 80),
  status      public.record_status not null default 'ACTIVE',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint expense_categories_business_id_id_key unique (business_id, id)
);

create unique index expense_categories_business_name_key
  on public.expense_categories (business_id, lower(name)) where status = 'ACTIVE';

create trigger set_updated_at
  before update on public.expense_categories
  for each row execute function private.set_updated_at();

create or replace function private.create_default_expense_categories(p_business_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.expense_categories (business_id, name)
  select p_business_id, n
    from unnest(array['Loyer', 'Électricité', 'Eau', 'Salaires', 'Transport', 'Fournitures',
                      'Internet et téléphone', 'Impôts et taxes', 'Entretien et réparations', 'Autres']) n
  on conflict do nothing;
$$;

create or replace function private.on_business_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.create_default_expense_categories(new.id);
  return null;
end;
$$;

create trigger on_business_created
  after insert on public.businesses
  for each row execute function private.on_business_created();

-- Backfill existing businesses.
select private.create_default_expense_categories(id) from public.businesses;

-- -----------------------------------------------------------------------------
-- expenses
-- -----------------------------------------------------------------------------
create table public.expenses (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses (id),
  category_id  uuid not null,
  -- NULL = business-wide expense (not tied to a store).
  location_id  uuid,
  amount       bigint not null check (amount > 0),
  description  text check (char_length(description) <= 500),
  spent_on     date not null default current_date,
  method       public.payment_method not null default 'CASH',
  -- Storage path in the private `documents` bucket.
  receipt_path text check (char_length(receipt_path) <= 500),
  created_by   uuid default auth.uid() references auth.users (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint expenses_business_id_id_key unique (business_id, id),
  constraint expenses_category_fkey foreign key (business_id, category_id)
    references public.expense_categories (business_id, id),
  constraint expenses_location_fkey foreign key (business_id, location_id)
    references public.locations (business_id, id),
  constraint expenses_receipt_path_scope_check
    check (receipt_path is null or receipt_path like business_id::text || '/expenses/%')
);

comment on table public.expenses is
  'Business expenses. Every change is audited with the full row (expense.create/update/delete).';

-- Expense journal by date and per category (reports).
create index expenses_business_id_spent_on_idx on public.expenses (business_id, spent_on desc);
create index expenses_business_id_category_id_idx on public.expenses (business_id, category_id);

create trigger set_updated_at
  before update on public.expenses
  for each row execute function private.set_updated_at();

create or replace function private.audit_expense()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform private.log_audit(new.business_id, 'expense.create', 'expense', new.id,
                              jsonb_build_object('new', to_jsonb(new)));
  elsif tg_op = 'UPDATE' then
    perform private.log_audit(new.business_id, 'expense.update', 'expense', new.id,
                              jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new)));
  else
    perform private.log_audit(old.business_id, 'expense.delete', 'expense', old.id,
                              jsonb_build_object('old', to_jsonb(old)));
  end if;
  return null;
end;
$$;

create trigger audit_expense
  after insert or update or delete on public.expenses
  for each row execute function private.audit_expense();

-- -----------------------------------------------------------------------------
-- employees
-- -----------------------------------------------------------------------------
create table public.employees (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses (id),
  full_name     text not null check (char_length(btrim(full_name)) between 1 and 120),
  phone         text check (phone ~ '^\+?[0-9]{6,15}$'),
  position      text check (char_length(position) <= 80),
  -- Monthly gross salary, business currency. Visible only with employees.read.
  salary_amount bigint check (salary_amount >= 0),
  hired_at      date,
  ended_at      date,
  notes         text check (char_length(notes) <= 1000),
  -- Optional link to the login account of this person in the business.
  member_id     uuid,
  status        public.record_status not null default 'ACTIVE',
  created_by    uuid default auth.uid() references auth.users (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint employees_business_id_id_key unique (business_id, id),
  constraint employees_member_fkey foreign key (business_id, member_id)
    references public.business_members (business_id, id) on delete set null (member_id),
  constraint employees_member_id_key unique (member_id),
  constraint employees_dates_check check (ended_at is null or hired_at is null or ended_at >= hired_at)
);

comment on table public.employees is
  'HR record of a person working for the business. Not a login account (see member_id).';

create index employees_business_id_full_name_idx on public.employees (business_id, full_name);

create trigger set_updated_at
  before update on public.employees
  for each row execute function private.set_updated_at();

create or replace function private.normalize_employee()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.full_name := btrim(new.full_name);
  new.phone     := nullif(regexp_replace(new.phone, '[\s.\-()]', '', 'g'), '');
  return new;
end;
$$;

create trigger normalize_employee
  before insert or update on public.employees
  for each row execute function private.normalize_employee();

create or replace function private.audit_employee_salary()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.log_audit(new.business_id, 'employee.salary_change', 'employee', new.id,
                            jsonb_build_object('old', old.salary_amount, 'new', new.salary_amount));
  return null;
end;
$$;

create trigger audit_employee_salary
  after update of salary_amount on public.employees
  for each row when (old.salary_amount is distinct from new.salary_amount)
  execute function private.audit_employee_salary();

-- -----------------------------------------------------------------------------
-- Privileges + RLS
-- -----------------------------------------------------------------------------
alter table public.expense_categories enable row level security;
alter table public.expenses           enable row level security;
alter table public.employees          enable row level security;

-- expense_categories: read with expenses.read, managed with expenses.manage.
grant select on public.expense_categories to authenticated;
grant insert (business_id, name) on public.expense_categories to authenticated;
grant update (name, status) on public.expense_categories to authenticated;

create policy "members with expenses.read can select expense categories"
  on public.expense_categories for select to authenticated
  using (business_id in (select private.businesses_with_permission('expenses.read')));

create policy "members with expenses.manage can insert expense categories"
  on public.expense_categories for insert to authenticated
  with check (business_id in (select private.businesses_with_permission('expenses.manage')));

create policy "members with expenses.manage can update expense categories"
  on public.expense_categories for update to authenticated
  using (business_id in (select private.businesses_with_permission('expenses.manage')))
  with check (business_id in (select private.businesses_with_permission('expenses.manage')));

-- expenses
grant select on public.expenses to authenticated;
grant insert (business_id, category_id, location_id, amount, description, spent_on, method, receipt_path)
  on public.expenses to authenticated;
grant update (category_id, location_id, amount, description, spent_on, method, receipt_path)
  on public.expenses to authenticated;
grant delete on public.expenses to authenticated;

create policy "members with expenses.read can select expenses"
  on public.expenses for select to authenticated
  using (business_id in (select private.businesses_with_permission('expenses.read')));

create policy "members with expenses.create can insert expenses"
  on public.expenses for insert to authenticated
  with check (business_id in (select private.businesses_with_permission('expenses.create')));

create policy "members with expenses.manage can update expenses"
  on public.expenses for update to authenticated
  using (business_id in (select private.businesses_with_permission('expenses.manage')))
  with check (business_id in (select private.businesses_with_permission('expenses.manage')));

create policy "members with expenses.manage can delete expenses"
  on public.expenses for delete to authenticated
  using (business_id in (select private.businesses_with_permission('expenses.manage')));

-- employees
grant select on public.employees to authenticated;
grant insert (business_id, full_name, phone, position, salary_amount, hired_at, ended_at, notes, member_id)
  on public.employees to authenticated;
grant update (full_name, phone, position, salary_amount, hired_at, ended_at, notes, member_id, status)
  on public.employees to authenticated;

create policy "members with employees.read can select employees"
  on public.employees for select to authenticated
  using (business_id in (select private.businesses_with_permission('employees.read')));

create policy "members with employees.manage can insert employees"
  on public.employees for insert to authenticated
  with check (business_id in (select private.businesses_with_permission('employees.manage')));

create policy "members with employees.manage can update employees"
  on public.employees for update to authenticated
  using (business_id in (select private.businesses_with_permission('employees.manage')))
  with check (business_id in (select private.businesses_with_permission('employees.manage')));

-- -----------------------------------------------------------------------------
-- Storage: private `documents` bucket — {business_id}/expenses/…
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 5 * 1024 * 1024,
        array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create policy "documents/expenses: members with expenses.read can read"
  on storage.objects for select to authenticated
  using (bucket_id = 'documents'
         and split_part(name, '/', 2) = 'expenses'
         and private.storage_business_id(name) in (select private.businesses_with_permission('expenses.read')));

create policy "documents/expenses: members with expenses.create can upload"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'documents'
              and split_part(name, '/', 2) = 'expenses'
              and private.storage_business_id(name) in (select private.businesses_with_permission('expenses.create')));

create policy "documents/expenses: members with expenses.manage can replace"
  on storage.objects for update to authenticated
  using (bucket_id = 'documents'
         and split_part(name, '/', 2) = 'expenses'
         and private.storage_business_id(name) in (select private.businesses_with_permission('expenses.manage')))
  with check (bucket_id = 'documents'
              and split_part(name, '/', 2) = 'expenses'
              and private.storage_business_id(name) in (select private.businesses_with_permission('expenses.manage')));

create policy "documents/expenses: members with expenses.manage can delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'documents'
         and split_part(name, '/', 2) = 'expenses'
         and private.storage_business_id(name) in (select private.businesses_with_permission('expenses.manage')));
