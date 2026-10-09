export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export type Database = {
  public: {
    Tables: {
      audit_logs: {
        Row: {
          action: string;
          actor_id: string | null;
          actor_role: string | null;
          business_id: string | null;
          created_at: string;
          id: string;
          metadata: NonNullable<Json>;
          resource_id: string | null;
          resource_type: string;
        };
        ComputedFields: never;
        Insert: {
          action: string;
          actor_id?: string | null;
          actor_role?: string | null;
          business_id?: string | null;
          created_at?: string;
          id?: string;
          metadata?: NonNullable<Json>;
          resource_id?: string | null;
          resource_type: string;
        };
        Update: {
          action?: string;
          actor_id?: string | null;
          actor_role?: string | null;
          business_id?: string | null;
          created_at?: string;
          id?: string;
          metadata?: NonNullable<Json>;
          resource_id?: string | null;
          resource_type?: string;
        };
        Relationships: [
          {
            foreignKeyName: "audit_logs_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      billing_events: {
        Row: {
          amount: number;
          business_id: string;
          event_id: string;
          id: string;
          months: number;
          plan_code: string;
          processed_at: string;
          provider: string;
          subscription_id: string | null;
        };
        ComputedFields: never;
        Insert: {
          amount: number;
          business_id: string;
          event_id: string;
          id?: string;
          months: number;
          plan_code: string;
          processed_at?: string;
          provider: string;
          subscription_id?: string | null;
        };
        Update: {
          amount?: number;
          business_id?: string;
          event_id?: string;
          id?: string;
          months?: number;
          plan_code?: string;
          processed_at?: string;
          provider?: string;
          subscription_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "billing_events_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "billing_events_subscription_id_fkey";
            columns: ["subscription_id"];
            isOneToOne: false;
            referencedRelation: "subscriptions";
            referencedColumns: ["id"];
          },
        ];
      };
      business_members: {
        Row: {
          business_id: string;
          created_at: string;
          id: string;
          invited_by: string | null;
          joined_at: string | null;
          role_id: string;
          status: Database["public"]["Enums"]["member_status"];
          updated_at: string;
          user_id: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          id?: string;
          invited_by?: string | null;
          joined_at?: string | null;
          role_id: string;
          status?: Database["public"]["Enums"]["member_status"];
          updated_at?: string;
          user_id: string;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          id?: string;
          invited_by?: string | null;
          joined_at?: string | null;
          role_id?: string;
          status?: Database["public"]["Enums"]["member_status"];
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "business_members_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "business_members_role_id_fkey";
            columns: ["role_id"];
            isOneToOne: false;
            referencedRelation: "roles";
            referencedColumns: ["id"];
          },
        ];
      };
      businesses: {
        Row: {
          address: string | null;
          allow_negative_stock: boolean;
          city: string | null;
          country_code: string;
          created_at: string;
          created_by: string | null;
          currency_code: string;
          email: string | null;
          id: string;
          large_sale_threshold: number | null;
          legal_name: string | null;
          logo_path: string | null;
          name: string;
          ninea: string | null;
          phone: string | null;
          rccm: string | null;
          status: Database["public"]["Enums"]["business_status"];
          timezone: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          address?: string | null;
          allow_negative_stock?: boolean;
          city?: string | null;
          country_code?: string;
          created_at?: string;
          created_by?: string | null;
          currency_code?: string;
          email?: string | null;
          id?: string;
          large_sale_threshold?: number | null;
          legal_name?: string | null;
          logo_path?: string | null;
          name: string;
          ninea?: string | null;
          phone?: string | null;
          rccm?: string | null;
          status?: Database["public"]["Enums"]["business_status"];
          timezone?: string;
          updated_at?: string;
        };
        Update: {
          address?: string | null;
          allow_negative_stock?: boolean;
          city?: string | null;
          country_code?: string;
          created_at?: string;
          created_by?: string | null;
          currency_code?: string;
          email?: string | null;
          id?: string;
          large_sale_threshold?: number | null;
          legal_name?: string | null;
          logo_path?: string | null;
          name?: string;
          ninea?: string | null;
          phone?: string | null;
          rccm?: string | null;
          status?: Database["public"]["Enums"]["business_status"];
          timezone?: string;
          updated_at?: string;
        };
        Relationships: [];
      };
      categories: {
        Row: {
          business_id: string;
          created_at: string;
          id: string;
          name: string;
          parent_id: string | null;
          status: Database["public"]["Enums"]["record_status"];
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          id?: string;
          name: string;
          parent_id?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          id?: string;
          name?: string;
          parent_id?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "categories_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "categories_parent_fkey";
            columns: ["business_id", "parent_id"];
            isOneToOne: false;
            referencedRelation: "categories";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      customer_transactions: {
        Row: {
          amount: number;
          balance_after: number;
          business_id: string;
          created_at: string;
          created_by: string | null;
          customer_id: string;
          id: string;
          note: string | null;
          payment_id: string | null;
          sale_id: string | null;
          type: Database["public"]["Enums"]["customer_transaction_type"];
        };
        ComputedFields: never;
        Insert: {
          amount: number;
          balance_after: number;
          business_id: string;
          created_at?: string;
          created_by?: string | null;
          customer_id: string;
          id?: string;
          note?: string | null;
          payment_id?: string | null;
          sale_id?: string | null;
          type: Database["public"]["Enums"]["customer_transaction_type"];
        };
        Update: {
          amount?: number;
          balance_after?: number;
          business_id?: string;
          created_at?: string;
          created_by?: string | null;
          customer_id?: string;
          id?: string;
          note?: string | null;
          payment_id?: string | null;
          sale_id?: string | null;
          type?: Database["public"]["Enums"]["customer_transaction_type"];
        };
        Relationships: [
          {
            foreignKeyName: "customer_transactions_customer_fkey";
            columns: ["business_id", "customer_id"];
            isOneToOne: false;
            referencedRelation: "customers";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "customer_transactions_payment_fkey";
            columns: ["business_id", "payment_id"];
            isOneToOne: false;
            referencedRelation: "payments";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "customer_transactions_sale_fkey";
            columns: ["business_id", "sale_id"];
            isOneToOne: false;
            referencedRelation: "sales";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      customers: {
        Row: {
          address: string | null;
          balance: number;
          business_id: string;
          created_at: string;
          created_by: string | null;
          credit_limit: number | null;
          email: string | null;
          id: string;
          name: string;
          notes: string | null;
          phone: string | null;
          status: Database["public"]["Enums"]["record_status"];
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          address?: string | null;
          balance?: number;
          business_id: string;
          created_at?: string;
          created_by?: string | null;
          credit_limit?: number | null;
          email?: string | null;
          id?: string;
          name: string;
          notes?: string | null;
          phone?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Update: {
          address?: string | null;
          balance?: number;
          business_id?: string;
          created_at?: string;
          created_by?: string | null;
          credit_limit?: number | null;
          email?: string | null;
          id?: string;
          name?: string;
          notes?: string | null;
          phone?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "customers_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      document_sequences: {
        Row: {
          business_id: string;
          doc_type: string;
          next_value: number;
          prefix: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          doc_type: string;
          next_value?: number;
          prefix: string;
        };
        Update: {
          business_id?: string;
          doc_type?: string;
          next_value?: number;
          prefix?: string;
        };
        Relationships: [
          {
            foreignKeyName: "document_sequences_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      employees: {
        Row: {
          business_id: string;
          created_at: string;
          created_by: string | null;
          ended_at: string | null;
          full_name: string;
          hired_at: string | null;
          id: string;
          member_id: string | null;
          notes: string | null;
          phone: string | null;
          position: string | null;
          salary_amount: number | null;
          status: Database["public"]["Enums"]["record_status"];
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          created_by?: string | null;
          ended_at?: string | null;
          full_name: string;
          hired_at?: string | null;
          id?: string;
          member_id?: string | null;
          notes?: string | null;
          phone?: string | null;
          position?: string | null;
          salary_amount?: number | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          created_by?: string | null;
          ended_at?: string | null;
          full_name?: string;
          hired_at?: string | null;
          id?: string;
          member_id?: string | null;
          notes?: string | null;
          phone?: string | null;
          position?: string | null;
          salary_amount?: number | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "employees_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "employees_member_fkey";
            columns: ["business_id", "member_id"];
            isOneToOne: false;
            referencedRelation: "business_members";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      expense_categories: {
        Row: {
          business_id: string;
          created_at: string;
          id: string;
          name: string;
          status: Database["public"]["Enums"]["record_status"];
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          id?: string;
          name: string;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          id?: string;
          name?: string;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "expense_categories_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      expenses: {
        Row: {
          amount: number;
          business_id: string;
          category_id: string;
          created_at: string;
          created_by: string | null;
          description: string | null;
          id: string;
          location_id: string | null;
          method: Database["public"]["Enums"]["payment_method"];
          receipt_path: string | null;
          spent_on: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          amount: number;
          business_id: string;
          category_id: string;
          created_at?: string;
          created_by?: string | null;
          description?: string | null;
          id?: string;
          location_id?: string | null;
          method?: Database["public"]["Enums"]["payment_method"];
          receipt_path?: string | null;
          spent_on?: string;
          updated_at?: string;
        };
        Update: {
          amount?: number;
          business_id?: string;
          category_id?: string;
          created_at?: string;
          created_by?: string | null;
          description?: string | null;
          id?: string;
          location_id?: string | null;
          method?: Database["public"]["Enums"]["payment_method"];
          receipt_path?: string | null;
          spent_on?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "expenses_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "expenses_category_fkey";
            columns: ["business_id", "category_id"];
            isOneToOne: false;
            referencedRelation: "expense_categories";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "expenses_location_fkey";
            columns: ["business_id", "location_id"];
            isOneToOne: false;
            referencedRelation: "locations";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      inventory: {
        Row: {
          business_id: string;
          location_id: string;
          product_id: string;
          quantity: number;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          location_id: string;
          product_id: string;
          quantity?: number;
          updated_at?: string;
        };
        Update: {
          business_id?: string;
          location_id?: string;
          product_id?: string;
          quantity?: number;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "inventory_location_fkey";
            columns: ["business_id", "location_id"];
            isOneToOne: false;
            referencedRelation: "locations";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "inventory_product_fkey";
            columns: ["business_id", "product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      inventory_movements: {
        Row: {
          business_id: string;
          created_at: string;
          created_by: string | null;
          id: string;
          location_id: string;
          product_id: string;
          quantity: number;
          quantity_after: number;
          reason: string | null;
          reference_id: string | null;
          reference_type: string | null;
          transfer_id: string | null;
          type: Database["public"]["Enums"]["inventory_movement_type"];
          unit_cost: number | null;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          location_id: string;
          product_id: string;
          quantity: number;
          quantity_after: number;
          reason?: string | null;
          reference_id?: string | null;
          reference_type?: string | null;
          transfer_id?: string | null;
          type: Database["public"]["Enums"]["inventory_movement_type"];
          unit_cost?: number | null;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          location_id?: string;
          product_id?: string;
          quantity?: number;
          quantity_after?: number;
          reason?: string | null;
          reference_id?: string | null;
          reference_type?: string | null;
          transfer_id?: string | null;
          type?: Database["public"]["Enums"]["inventory_movement_type"];
          unit_cost?: number | null;
        };
        Relationships: [
          {
            foreignKeyName: "inventory_movements_location_fkey";
            columns: ["business_id", "location_id"];
            isOneToOne: false;
            referencedRelation: "locations";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "inventory_movements_product_fkey";
            columns: ["business_id", "product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      locations: {
        Row: {
          address: string | null;
          business_id: string;
          created_at: string;
          id: string;
          is_default: boolean;
          name: string;
          status: Database["public"]["Enums"]["record_status"];
          type: Database["public"]["Enums"]["location_type"];
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          address?: string | null;
          business_id: string;
          created_at?: string;
          id?: string;
          is_default?: boolean;
          name: string;
          status?: Database["public"]["Enums"]["record_status"];
          type?: Database["public"]["Enums"]["location_type"];
          updated_at?: string;
        };
        Update: {
          address?: string | null;
          business_id?: string;
          created_at?: string;
          id?: string;
          is_default?: boolean;
          name?: string;
          status?: Database["public"]["Enums"]["record_status"];
          type?: Database["public"]["Enums"]["location_type"];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "locations_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      notifications: {
        Row: {
          body: string | null;
          business_id: string | null;
          created_at: string;
          data: NonNullable<Json>;
          id: string;
          read_at: string | null;
          resource_id: string | null;
          resource_type: string | null;
          title: string;
          type: Database["public"]["Enums"]["notification_type"];
          user_id: string;
        };
        ComputedFields: never;
        Insert: {
          body?: string | null;
          business_id?: string | null;
          created_at?: string;
          data?: NonNullable<Json>;
          id?: string;
          read_at?: string | null;
          resource_id?: string | null;
          resource_type?: string | null;
          title: string;
          type: Database["public"]["Enums"]["notification_type"];
          user_id: string;
        };
        Update: {
          body?: string | null;
          business_id?: string | null;
          created_at?: string;
          data?: NonNullable<Json>;
          id?: string;
          read_at?: string | null;
          resource_id?: string | null;
          resource_type?: string | null;
          title?: string;
          type?: Database["public"]["Enums"]["notification_type"];
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "notifications_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      payments: {
        Row: {
          amount: number;
          business_id: string;
          created_at: string;
          customer_id: string | null;
          direction: Database["public"]["Enums"]["payment_direction"];
          external_reference: string | null;
          id: string;
          location_id: string;
          method: Database["public"]["Enums"]["payment_method"];
          note: string | null;
          paid_at: string;
          purchase_id: string | null;
          recorded_by: string | null;
          sale_id: string | null;
        };
        ComputedFields: never;
        Insert: {
          amount: number;
          business_id: string;
          created_at?: string;
          customer_id?: string | null;
          direction: Database["public"]["Enums"]["payment_direction"];
          external_reference?: string | null;
          id?: string;
          location_id: string;
          method: Database["public"]["Enums"]["payment_method"];
          note?: string | null;
          paid_at?: string;
          purchase_id?: string | null;
          recorded_by?: string | null;
          sale_id?: string | null;
        };
        Update: {
          amount?: number;
          business_id?: string;
          created_at?: string;
          customer_id?: string | null;
          direction?: Database["public"]["Enums"]["payment_direction"];
          external_reference?: string | null;
          id?: string;
          location_id?: string;
          method?: Database["public"]["Enums"]["payment_method"];
          note?: string | null;
          paid_at?: string;
          purchase_id?: string | null;
          recorded_by?: string | null;
          sale_id?: string | null;
        };
        Relationships: [
          {
            foreignKeyName: "payments_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "payments_customer_fkey";
            columns: ["business_id", "customer_id"];
            isOneToOne: false;
            referencedRelation: "customers";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "payments_location_fkey";
            columns: ["business_id", "location_id"];
            isOneToOne: false;
            referencedRelation: "locations";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "payments_purchase_fkey";
            columns: ["business_id", "purchase_id"];
            isOneToOne: false;
            referencedRelation: "purchases";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "payments_sale_fkey";
            columns: ["business_id", "sale_id"];
            isOneToOne: false;
            referencedRelation: "sales";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      permissions: {
        Row: {
          allowed_when_restricted: boolean;
          code: string;
          created_at: string;
          description: string;
          module: string;
        };
        ComputedFields: never;
        Insert: {
          allowed_when_restricted?: boolean;
          code: string;
          created_at?: string;
          description: string;
          module: string;
        };
        Update: {
          allowed_when_restricted?: boolean;
          code?: string;
          created_at?: string;
          description?: string;
          module?: string;
        };
        Relationships: [];
      };
      platform_admins: {
        Row: {
          created_at: string;
          created_by: string | null;
          role: Database["public"]["Enums"]["platform_role"];
          status: Database["public"]["Enums"]["platform_admin_status"];
          updated_at: string;
          user_id: string;
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          created_by?: string | null;
          role: Database["public"]["Enums"]["platform_role"];
          status?: Database["public"]["Enums"]["platform_admin_status"];
          updated_at?: string;
          user_id: string;
        };
        Update: {
          created_at?: string;
          created_by?: string | null;
          role?: Database["public"]["Enums"]["platform_role"];
          status?: Database["public"]["Enums"]["platform_admin_status"];
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [];
      };
      platform_announcements: {
        Row: {
          audience: Database["public"]["Enums"]["announcement_audience"];
          audience_value: string | null;
          body: string;
          created_at: string;
          created_by: string | null;
          id: string;
          recipients_count: number | null;
          sent_at: string | null;
          sent_by: string | null;
          status: Database["public"]["Enums"]["announcement_status"];
          title: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          audience?: Database["public"]["Enums"]["announcement_audience"];
          audience_value?: string | null;
          body: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          recipients_count?: number | null;
          sent_at?: string | null;
          sent_by?: string | null;
          status?: Database["public"]["Enums"]["announcement_status"];
          title: string;
          updated_at?: string;
        };
        Update: {
          audience?: Database["public"]["Enums"]["announcement_audience"];
          audience_value?: string | null;
          body?: string;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          recipients_count?: number | null;
          sent_at?: string | null;
          sent_by?: string | null;
          status?: Database["public"]["Enums"]["announcement_status"];
          title?: string;
          updated_at?: string;
        };
        Relationships: [];
      };
      platform_permissions: {
        Row: {
          code: string;
          created_at: string;
          description: string;
        };
        ComputedFields: never;
        Insert: {
          code: string;
          created_at?: string;
          description: string;
        };
        Update: {
          code?: string;
          created_at?: string;
          description?: string;
        };
        Relationships: [];
      };
      platform_role_permissions: {
        Row: {
          created_at: string;
          permission_code: string;
          role: Database["public"]["Enums"]["platform_role"];
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          permission_code: string;
          role: Database["public"]["Enums"]["platform_role"];
        };
        Update: {
          created_at?: string;
          permission_code?: string;
          role?: Database["public"]["Enums"]["platform_role"];
        };
        Relationships: [
          {
            foreignKeyName: "platform_role_permissions_permission_code_fkey";
            columns: ["permission_code"];
            isOneToOne: false;
            referencedRelation: "platform_permissions";
            referencedColumns: ["code"];
          },
        ];
      };
      product_costs: {
        Row: {
          business_id: string;
          cost_price: number;
          created_at: string;
          product_id: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          cost_price?: number;
          created_at?: string;
          product_id: string;
          updated_at?: string;
        };
        Update: {
          business_id?: string;
          cost_price?: number;
          created_at?: string;
          product_id?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "product_costs_product_fkey";
            columns: ["business_id", "product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      products: {
        Row: {
          allows_fractional_quantity: boolean;
          barcode: string | null;
          business_id: string;
          category_id: string | null;
          created_at: string;
          created_by: string | null;
          description: string | null;
          id: string;
          image_path: string | null;
          min_stock_level: number;
          name: string;
          sale_price: number;
          sku: string | null;
          status: Database["public"]["Enums"]["record_status"];
          track_stock: boolean;
          unit: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          allows_fractional_quantity?: boolean;
          barcode?: string | null;
          business_id: string;
          category_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          description?: string | null;
          id?: string;
          image_path?: string | null;
          min_stock_level?: number;
          name: string;
          sale_price?: number;
          sku?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          track_stock?: boolean;
          unit?: string;
          updated_at?: string;
        };
        Update: {
          allows_fractional_quantity?: boolean;
          barcode?: string | null;
          business_id?: string;
          category_id?: string | null;
          created_at?: string;
          created_by?: string | null;
          description?: string | null;
          id?: string;
          image_path?: string | null;
          min_stock_level?: number;
          name?: string;
          sale_price?: number;
          sku?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          track_stock?: boolean;
          unit?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "products_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "products_category_fkey";
            columns: ["business_id", "category_id"];
            isOneToOne: false;
            referencedRelation: "categories";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      profiles: {
        Row: {
          avatar_path: string | null;
          created_at: string;
          full_name: string | null;
          id: string;
          locale: string;
          phone: string | null;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          avatar_path?: string | null;
          created_at?: string;
          full_name?: string | null;
          id: string;
          locale?: string;
          phone?: string | null;
          updated_at?: string;
        };
        Update: {
          avatar_path?: string | null;
          created_at?: string;
          full_name?: string | null;
          id?: string;
          locale?: string;
          phone?: string | null;
          updated_at?: string;
        };
        Relationships: [];
      };
      purchase_items: {
        Row: {
          business_id: string;
          created_at: string;
          id: string;
          line_total: number;
          product_id: string;
          purchase_id: string;
          quantity: number;
          unit_cost: number;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          id?: string;
          line_total: number;
          product_id: string;
          purchase_id: string;
          quantity: number;
          unit_cost: number;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          id?: string;
          line_total?: number;
          product_id?: string;
          purchase_id?: string;
          quantity?: number;
          unit_cost?: number;
        };
        Relationships: [
          {
            foreignKeyName: "purchase_items_product_fkey";
            columns: ["business_id", "product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "purchase_items_purchase_fkey";
            columns: ["business_id", "purchase_id"];
            isOneToOne: false;
            referencedRelation: "purchases";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      purchases: {
        Row: {
          amount_paid: number;
          business_id: string;
          cancel_reason: string | null;
          cancelled_at: string | null;
          cancelled_by: string | null;
          created_at: string;
          created_by: string | null;
          discount_amount: number;
          id: string;
          location_id: string;
          notes: string | null;
          number: string;
          ordered_at: string | null;
          payment_status: Database["public"]["Enums"]["payment_status"] | null;
          received_at: string | null;
          received_by: string | null;
          status: Database["public"]["Enums"]["purchase_status"];
          subtotal_amount: number;
          supplier_id: string | null;
          supplier_reference: string | null;
          total_amount: number;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          amount_paid?: number;
          business_id: string;
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by?: string | null;
          created_at?: string;
          created_by?: string | null;
          discount_amount?: number;
          id?: string;
          location_id: string;
          notes?: string | null;
          number: string;
          ordered_at?: string | null;
          payment_status?: never;
          received_at?: string | null;
          received_by?: string | null;
          status?: Database["public"]["Enums"]["purchase_status"];
          subtotal_amount?: number;
          supplier_id?: string | null;
          supplier_reference?: string | null;
          total_amount?: number;
          updated_at?: string;
        };
        Update: {
          amount_paid?: number;
          business_id?: string;
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by?: string | null;
          created_at?: string;
          created_by?: string | null;
          discount_amount?: number;
          id?: string;
          location_id?: string;
          notes?: string | null;
          number?: string;
          ordered_at?: string | null;
          payment_status?: never;
          received_at?: string | null;
          received_by?: string | null;
          status?: Database["public"]["Enums"]["purchase_status"];
          subtotal_amount?: number;
          supplier_id?: string | null;
          supplier_reference?: string | null;
          total_amount?: number;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "purchases_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "purchases_location_fkey";
            columns: ["business_id", "location_id"];
            isOneToOne: false;
            referencedRelation: "locations";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "purchases_supplier_fkey";
            columns: ["business_id", "supplier_id"];
            isOneToOne: false;
            referencedRelation: "suppliers";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      role_permissions: {
        Row: {
          created_at: string;
          permission_code: string;
          role_id: string;
        };
        ComputedFields: never;
        Insert: {
          created_at?: string;
          permission_code: string;
          role_id: string;
        };
        Update: {
          created_at?: string;
          permission_code?: string;
          role_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "role_permissions_permission_code_fkey";
            columns: ["permission_code"];
            isOneToOne: false;
            referencedRelation: "permissions";
            referencedColumns: ["code"];
          },
          {
            foreignKeyName: "role_permissions_role_id_fkey";
            columns: ["role_id"];
            isOneToOne: false;
            referencedRelation: "roles";
            referencedColumns: ["id"];
          },
        ];
      };
      roles: {
        Row: {
          business_id: string | null;
          code: string;
          created_at: string;
          description: string | null;
          id: string;
          is_system: boolean;
          name: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          business_id?: string | null;
          code: string;
          created_at?: string;
          description?: string | null;
          id?: string;
          is_system?: boolean;
          name: string;
          updated_at?: string;
        };
        Update: {
          business_id?: string | null;
          code?: string;
          created_at?: string;
          description?: string | null;
          id?: string;
          is_system?: boolean;
          name?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "roles_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      sale_item_costs: {
        Row: {
          business_id: string;
          sale_item_id: string;
          unit_cost: number;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          sale_item_id: string;
          unit_cost: number;
        };
        Update: {
          business_id?: string;
          sale_item_id?: string;
          unit_cost?: number;
        };
        Relationships: [
          {
            foreignKeyName: "sale_item_costs_item_fkey";
            columns: ["business_id", "sale_item_id"];
            isOneToOne: false;
            referencedRelation: "sale_items";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      sale_items: {
        Row: {
          business_id: string;
          created_at: string;
          discount_amount: number;
          id: string;
          line_total: number;
          product_id: string;
          product_name: string;
          quantity: number;
          sale_id: string;
          unit_price: number;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          discount_amount?: number;
          id?: string;
          line_total: number;
          product_id: string;
          product_name: string;
          quantity: number;
          sale_id: string;
          unit_price: number;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          discount_amount?: number;
          id?: string;
          line_total?: number;
          product_id?: string;
          product_name?: string;
          quantity?: number;
          sale_id?: string;
          unit_price?: number;
        };
        Relationships: [
          {
            foreignKeyName: "sale_items_product_fkey";
            columns: ["business_id", "product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "sale_items_sale_fkey";
            columns: ["business_id", "sale_id"];
            isOneToOne: false;
            referencedRelation: "sales";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      sales: {
        Row: {
          amount_paid: number;
          business_id: string;
          cancel_reason: string | null;
          cancelled_at: string | null;
          cancelled_by: string | null;
          client_reference: string;
          created_at: string;
          credit_amount: number;
          customer_id: string | null;
          discount_amount: number;
          id: string;
          location_id: string;
          notes: string | null;
          number: string;
          payment_status: Database["public"]["Enums"]["payment_status"] | null;
          sold_at: string;
          sold_by: string | null;
          status: Database["public"]["Enums"]["sale_status"];
          subtotal_amount: number;
          total_amount: number;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          amount_paid?: number;
          business_id: string;
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by?: string | null;
          client_reference: string;
          created_at?: string;
          credit_amount?: number;
          customer_id?: string | null;
          discount_amount?: number;
          id?: string;
          location_id: string;
          notes?: string | null;
          number: string;
          payment_status?: never;
          sold_at?: string;
          sold_by?: string | null;
          status?: Database["public"]["Enums"]["sale_status"];
          subtotal_amount: number;
          total_amount: number;
          updated_at?: string;
        };
        Update: {
          amount_paid?: number;
          business_id?: string;
          cancel_reason?: string | null;
          cancelled_at?: string | null;
          cancelled_by?: string | null;
          client_reference?: string;
          created_at?: string;
          credit_amount?: number;
          customer_id?: string | null;
          discount_amount?: number;
          id?: string;
          location_id?: string;
          notes?: string | null;
          number?: string;
          payment_status?: never;
          sold_at?: string;
          sold_by?: string | null;
          status?: Database["public"]["Enums"]["sale_status"];
          subtotal_amount?: number;
          total_amount?: number;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "sales_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "sales_customer_fkey";
            columns: ["business_id", "customer_id"];
            isOneToOne: false;
            referencedRelation: "customers";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "sales_location_fkey";
            columns: ["business_id", "location_id"];
            isOneToOne: false;
            referencedRelation: "locations";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      subscription_plans: {
        Row: {
          billing_period: Database["public"]["Enums"]["billing_period"];
          code: string;
          created_at: string;
          currency_code: string;
          description: string | null;
          features: NonNullable<Json>;
          id: string;
          is_public: boolean;
          limits: NonNullable<Json>;
          name: string;
          price_amount: number;
          sort_order: number;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          billing_period?: Database["public"]["Enums"]["billing_period"];
          code: string;
          created_at?: string;
          currency_code?: string;
          description?: string | null;
          features?: NonNullable<Json>;
          id?: string;
          is_public?: boolean;
          limits?: NonNullable<Json>;
          name: string;
          price_amount?: number;
          sort_order?: number;
          updated_at?: string;
        };
        Update: {
          billing_period?: Database["public"]["Enums"]["billing_period"];
          code?: string;
          created_at?: string;
          currency_code?: string;
          description?: string | null;
          features?: NonNullable<Json>;
          id?: string;
          is_public?: boolean;
          limits?: NonNullable<Json>;
          name?: string;
          price_amount?: number;
          sort_order?: number;
          updated_at?: string;
        };
        Relationships: [];
      };
      subscriptions: {
        Row: {
          business_id: string;
          cancel_at_period_end: boolean;
          created_at: string;
          current_period_end: string | null;
          current_period_start: string | null;
          ended_at: string | null;
          external_reference: string | null;
          id: string;
          plan_id: string;
          status: Database["public"]["Enums"]["subscription_status"];
          trial_ends_at: string | null;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          cancel_at_period_end?: boolean;
          created_at?: string;
          current_period_end?: string | null;
          current_period_start?: string | null;
          ended_at?: string | null;
          external_reference?: string | null;
          id?: string;
          plan_id: string;
          status: Database["public"]["Enums"]["subscription_status"];
          trial_ends_at?: string | null;
          updated_at?: string;
        };
        Update: {
          business_id?: string;
          cancel_at_period_end?: boolean;
          created_at?: string;
          current_period_end?: string | null;
          current_period_start?: string | null;
          ended_at?: string | null;
          external_reference?: string | null;
          id?: string;
          plan_id?: string;
          status?: Database["public"]["Enums"]["subscription_status"];
          trial_ends_at?: string | null;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "subscriptions_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "subscriptions_plan_id_fkey";
            columns: ["plan_id"];
            isOneToOne: false;
            referencedRelation: "subscription_plans";
            referencedColumns: ["id"];
          },
        ];
      };
      supplier_products: {
        Row: {
          business_id: string;
          created_at: string;
          last_cost: number | null;
          product_id: string;
          supplier_id: string;
          supplier_sku: string | null;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          business_id: string;
          created_at?: string;
          last_cost?: number | null;
          product_id: string;
          supplier_id: string;
          supplier_sku?: string | null;
          updated_at?: string;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          last_cost?: number | null;
          product_id?: string;
          supplier_id?: string;
          supplier_sku?: string | null;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "supplier_products_product_fkey";
            columns: ["business_id", "product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["business_id", "id"];
          },
          {
            foreignKeyName: "supplier_products_supplier_fkey";
            columns: ["business_id", "supplier_id"];
            isOneToOne: false;
            referencedRelation: "suppliers";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
      suppliers: {
        Row: {
          address: string | null;
          business_id: string;
          contact_name: string | null;
          created_at: string;
          created_by: string | null;
          email: string | null;
          id: string;
          name: string;
          notes: string | null;
          phone: string | null;
          status: Database["public"]["Enums"]["record_status"];
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          address?: string | null;
          business_id: string;
          contact_name?: string | null;
          created_at?: string;
          created_by?: string | null;
          email?: string | null;
          id?: string;
          name: string;
          notes?: string | null;
          phone?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Update: {
          address?: string | null;
          business_id?: string;
          contact_name?: string | null;
          created_at?: string;
          created_by?: string | null;
          email?: string | null;
          id?: string;
          name?: string;
          notes?: string | null;
          phone?: string | null;
          status?: Database["public"]["Enums"]["record_status"];
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "suppliers_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      support_messages: {
        Row: {
          author_id: string | null;
          body: string;
          created_at: string;
          id: string;
          is_internal: boolean;
          is_staff: boolean;
          ticket_id: string;
        };
        ComputedFields: never;
        Insert: {
          author_id?: string | null;
          body: string;
          created_at?: string;
          id?: string;
          is_internal?: boolean;
          is_staff?: boolean;
          ticket_id: string;
        };
        Update: {
          author_id?: string | null;
          body?: string;
          created_at?: string;
          id?: string;
          is_internal?: boolean;
          is_staff?: boolean;
          ticket_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "support_messages_ticket_id_fkey";
            columns: ["ticket_id"];
            isOneToOne: false;
            referencedRelation: "support_tickets";
            referencedColumns: ["id"];
          },
        ];
      };
      support_tickets: {
        Row: {
          assigned_to: string | null;
          business_id: string | null;
          closed_at: string | null;
          created_at: string;
          created_by: string | null;
          id: string;
          last_message_at: string;
          number: number;
          priority: Database["public"]["Enums"]["ticket_priority"];
          resolved_at: string | null;
          status: Database["public"]["Enums"]["ticket_status"];
          subject: string;
          updated_at: string;
        };
        ComputedFields: never;
        Insert: {
          assigned_to?: string | null;
          business_id?: string | null;
          closed_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          last_message_at?: string;
          number?: never;
          priority?: Database["public"]["Enums"]["ticket_priority"];
          resolved_at?: string | null;
          status?: Database["public"]["Enums"]["ticket_status"];
          subject: string;
          updated_at?: string;
        };
        Update: {
          assigned_to?: string | null;
          business_id?: string | null;
          closed_at?: string | null;
          created_at?: string;
          created_by?: string | null;
          id?: string;
          last_message_at?: string;
          number?: never;
          priority?: Database["public"]["Enums"]["ticket_priority"];
          resolved_at?: string | null;
          status?: Database["public"]["Enums"]["ticket_status"];
          subject?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "support_tickets_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
    };
    Views: {
      supplier_balances: {
        Row: {
          advances_paid: number | null;
          amount_due: number | null;
          business_id: string | null;
          supplier_id: string | null;
          unpaid_purchases: number | null;
        };
        ComputedFields: never;
        Relationships: [
          {
            foreignKeyName: "purchases_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "purchases_supplier_fkey";
            columns: ["business_id", "supplier_id"];
            isOneToOne: false;
            referencedRelation: "suppliers";
            referencedColumns: ["business_id", "id"];
          },
        ];
      };
    };
    Functions: {
      accept_invitation: {
        Args: { p_business_id: string };
        Returns: undefined;
      };
      adjust_customer_balance: {
        Args: { p_amount: number; p_customer_id: string; p_reason: string };
        Returns: string;
      };
      adjust_stock: {
        Args: {
          p_business_id: string;
          p_location_id: string;
          p_product_id: string;
          p_quantity: number;
          p_reason?: string;
          p_type: Database["public"]["Enums"]["inventory_movement_type"];
        };
        Returns: string;
      };
      admin_count_announcement_recipients: {
        Args: {
          p_audience: Database["public"]["Enums"]["announcement_audience"];
          p_audience_value?: string;
        };
        Returns: number;
      };
      admin_delete_announcement: { Args: { p_id: string }; Returns: undefined };
      admin_get_audit_log: {
        Args: {
          p_action?: string;
          p_actor_id?: string;
          p_before?: string;
          p_before_id?: string;
          p_business_id?: string;
          p_from?: string;
          p_limit?: number;
          p_resource_type?: string;
          p_to?: string;
        };
        Returns: {
          action: string;
          actor_email: string;
          actor_id: string;
          actor_name: string;
          actor_role: string;
          business_id: string;
          business_name: string;
          created_at: string;
          id: string;
          metadata: Json;
          resource_id: string;
          resource_type: string;
        }[];
      };
      admin_get_business: { Args: { p_business_id: string }; Returns: Json };
      admin_get_overview: {
        Args: { p_from: string; p_to: string };
        Returns: Json;
      };
      admin_get_support_ticket: {
        Args: { p_ticket_id: string };
        Returns: Json;
      };
      admin_get_timeseries: {
        Args: { p_from: string; p_granularity?: string; p_to: string };
        Returns: {
          active_businesses: number;
          bucket: string;
          collected: number;
          gmv: number;
          new_businesses: number;
          new_users: number;
          payments_count: number;
          sales_count: number;
        }[];
      };
      admin_get_user: { Args: { p_user_id: string }; Returns: Json };
      admin_grant_platform_role: {
        Args: {
          p_email: string;
          p_role: Database["public"]["Enums"]["platform_role"];
        };
        Returns: string;
      };
      admin_list_admins: {
        Args: Record<PropertyKey, never>;
        Returns: {
          created_at: string;
          email: string;
          full_name: string;
          last_sign_in_at: string;
          role: Database["public"]["Enums"]["platform_role"];
          status: Database["public"]["Enums"]["platform_admin_status"];
          user_id: string;
        }[];
      };
      admin_list_announcements: {
        Args: { p_limit?: number; p_offset?: number };
        Returns: {
          audience: Database["public"]["Enums"]["announcement_audience"];
          audience_label: string;
          audience_value: string;
          body: string;
          created_at: string;
          created_by_name: string;
          id: string;
          recipients_count: number;
          sent_at: string;
          sent_by_name: string;
          status: Database["public"]["Enums"]["announcement_status"];
          title: string;
          total_count: number;
        }[];
      };
      admin_list_billing_events: {
        Args: {
          p_from?: string;
          p_limit?: number;
          p_offset?: number;
          p_provider?: string;
          p_search?: string;
          p_to?: string;
        };
        Returns: {
          amount: number;
          business_id: string;
          business_name: string;
          event_id: string;
          id: string;
          months: number;
          plan_code: string;
          processed_at: string;
          provider: string;
          total_count: number;
        }[];
      };
      admin_list_business_members: {
        Args: { p_business_id: string };
        Returns: {
          created_at: string;
          email: string;
          full_name: string;
          joined_at: string;
          last_sign_in_at: string;
          member_id: string;
          phone: string;
          role_code: string;
          role_name: string;
          status: Database["public"]["Enums"]["member_status"];
          user_id: string;
        }[];
      };
      admin_list_businesses: {
        Args: {
          p_created_from?: string;
          p_created_to?: string;
          p_limit?: number;
          p_offset?: number;
          p_plan_code?: string;
          p_search?: string;
          p_sort?: string;
          p_status?: Database["public"]["Enums"]["business_status"];
          p_subscription_status?: Database["public"]["Enums"]["subscription_status"];
        };
        Returns: {
          city: string;
          country_code: string;
          created_at: string;
          current_period_end: string;
          email: string;
          id: string;
          last_sale_at: string;
          members_count: number;
          name: string;
          owner_email: string;
          owner_name: string;
          phone: string;
          plan_code: string;
          plan_name: string;
          status: Database["public"]["Enums"]["business_status"];
          subscription_status: Database["public"]["Enums"]["subscription_status"];
          total_count: number;
          trial_ends_at: string;
        }[];
      };
      admin_list_subscriptions: {
        Args: {
          p_current_only?: boolean;
          p_ending_within_days?: number;
          p_limit?: number;
          p_offset?: number;
          p_plan_code?: string;
          p_search?: string;
          p_status?: Database["public"]["Enums"]["subscription_status"];
        };
        Returns: {
          billing_period: Database["public"]["Enums"]["billing_period"];
          business_id: string;
          business_name: string;
          business_status: Database["public"]["Enums"]["business_status"];
          cancel_at_period_end: boolean;
          created_at: string;
          current_period_end: string;
          current_period_start: string;
          ended_at: string;
          external_reference: string;
          id: string;
          plan_code: string;
          plan_name: string;
          price_amount: number;
          status: Database["public"]["Enums"]["subscription_status"];
          total_count: number;
          trial_ends_at: string;
        }[];
      };
      admin_list_support_tickets: {
        Args: {
          p_assigned_to?: string;
          p_business_id?: string;
          p_limit?: number;
          p_offset?: number;
          p_open_only?: boolean;
          p_priority?: Database["public"]["Enums"]["ticket_priority"];
          p_search?: string;
          p_status?: Database["public"]["Enums"]["ticket_status"];
          p_unassigned?: boolean;
        };
        Returns: {
          assigned_to: string;
          assignee_name: string;
          business_id: string;
          business_name: string;
          created_at: string;
          created_by: string;
          id: string;
          last_message_at: string;
          messages_count: number;
          number: number;
          priority: Database["public"]["Enums"]["ticket_priority"];
          requester_email: string;
          requester_name: string;
          status: Database["public"]["Enums"]["ticket_status"];
          subject: string;
          total_count: number;
        }[];
      };
      admin_list_users: {
        Args: { p_limit?: number; p_offset?: number; p_search?: string };
        Returns: {
          businesses_count: number;
          created_at: string;
          email: string;
          email_confirmed: boolean;
          full_name: string;
          id: string;
          last_sign_in_at: string;
          phone: string;
          platform_role: Database["public"]["Enums"]["platform_role"];
          total_count: number;
        }[];
      };
      admin_record_manual_payment: {
        Args: {
          p_amount: number;
          p_business_id: string;
          p_months: number;
          p_note?: string;
          p_plan_code: string;
          p_reference: string;
        };
        Returns: Json;
      };
      admin_reply_support_ticket: {
        Args: { p_body: string; p_internal?: boolean; p_ticket_id: string };
        Returns: string;
      };
      admin_save_announcement: {
        Args: {
          p_audience: Database["public"]["Enums"]["announcement_audience"];
          p_audience_value?: string;
          p_body: string;
          p_id: string;
          p_title: string;
        };
        Returns: string;
      };
      admin_send_announcement: { Args: { p_id: string }; Returns: number };
      admin_set_admin_status: {
        Args: {
          p_status: Database["public"]["Enums"]["platform_admin_status"];
          p_user_id: string;
        };
        Returns: undefined;
      };
      admin_set_business_status: {
        Args: {
          p_business_id: string;
          p_reason: string;
          p_status: Database["public"]["Enums"]["business_status"];
        };
        Returns: undefined;
      };
      admin_update_support_ticket: {
        Args: {
          p_assigned_to?: string;
          p_priority?: Database["public"]["Enums"]["ticket_priority"];
          p_status?: Database["public"]["Enums"]["ticket_status"];
          p_ticket_id: string;
          p_unassign?: boolean;
        };
        Returns: undefined;
      };
      cancel_purchase: {
        Args: { p_purchase_id: string; p_reason: string };
        Returns: undefined;
      };
      cancel_sale: {
        Args: {
          p_reason: string;
          p_refund_method?: Database["public"]["Enums"]["payment_method"];
          p_sale_id: string;
        };
        Returns: undefined;
      };
      change_member_role: {
        Args: { p_business_id: string; p_role_code: string; p_user_id: string };
        Returns: undefined;
      };
      count_stock: {
        Args: {
          p_business_id: string;
          p_counted_quantity: number;
          p_location_id: string;
          p_product_id: string;
          p_reason?: string;
        };
        Returns: string;
      };
      create_business: {
        Args: {
          p_address?: string;
          p_city?: string;
          p_name: string;
          p_phone?: string;
        };
        Returns: string;
      };
      create_sale: {
        Args: {
          p_business_id: string;
          p_client_reference: string;
          p_customer_id?: string;
          p_discount_amount?: number;
          p_items: Json;
          p_location_id: string;
          p_notes?: string;
          p_payments?: Json;
        };
        Returns: string;
      };
      create_support_ticket: {
        Args: {
          p_body: string;
          p_business_id?: string;
          p_priority?: Database["public"]["Enums"]["ticket_priority"];
          p_subject: string;
        };
        Returns: string;
      };
      decline_invitation: {
        Args: { p_business_id: string };
        Returns: undefined;
      };
      get_audit_log: {
        Args: {
          p_action?: string;
          p_actor_id?: string;
          p_before?: string;
          p_before_id?: string;
          p_business_id: string;
          p_limit?: number;
          p_resource_id?: string;
          p_resource_type?: string;
        };
        Returns: {
          action: string;
          actor_id: string;
          actor_name: string;
          actor_role: string;
          created_at: string;
          id: string;
          metadata: Json;
          resource_id: string;
          resource_type: string;
        }[];
      };
      get_dashboard_summary: {
        Args: {
          p_business_id: string;
          p_from: string;
          p_location_id?: string;
          p_to: string;
        };
        Returns: Json;
      };
      get_my_permissions: {
        Args: { p_business_id: string };
        Returns: string[];
      };
      get_my_platform_access: {
        Args: Record<PropertyKey, never>;
        Returns: {
          permissions: string[];
          role: Database["public"]["Enums"]["platform_role"];
          status: Database["public"]["Enums"]["platform_admin_status"];
        }[];
      };
      get_sales_timeseries: {
        Args: {
          p_business_id: string;
          p_from: string;
          p_granularity?: string;
          p_location_id?: string;
          p_to: string;
        };
        Returns: {
          estimated_margin: number;
          period: string;
          revenue: number;
          sales_count: number;
        }[];
      };
      get_subscription_status: {
        Args: { p_business_id: string };
        Returns: {
          current_period_end: string;
          is_restricted: boolean;
          limits: Json;
          plan_code: string;
          plan_name: string;
          status: Database["public"]["Enums"]["subscription_status"];
          trial_ends_at: string;
          usage: Json;
        }[];
      };
      get_top_products: {
        Args: {
          p_business_id: string;
          p_from: string;
          p_limit?: number;
          p_location_id?: string;
          p_to: string;
        };
        Returns: {
          estimated_margin: number;
          product_id: string;
          product_name: string;
          quantity: number;
          revenue: number;
        }[];
      };
      invite_member: {
        Args: { p_business_id: string; p_email: string; p_role_code: string };
        Returns: string;
      };
      leave_business: { Args: { p_business_id: string }; Returns: undefined };
      list_business_members: {
        Args: { p_business_id: string };
        Returns: {
          avatar_path: string;
          email: string;
          full_name: string;
          joined_at: string;
          phone: string;
          role_code: string;
          role_name: string;
          status: Database["public"]["Enums"]["member_status"];
          user_id: string;
        }[];
      };
      list_low_stock: {
        Args: { p_business_id: string; p_location_id?: string };
        Returns: {
          location_id: string;
          location_name: string;
          min_stock_level: number;
          product_id: string;
          product_name: string;
          quantity: number;
        }[];
      };
      list_my_invitations: {
        Args: Record<PropertyKey, never>;
        Returns: {
          business_id: string;
          business_name: string;
          invited_at: string;
          role_code: string;
          role_name: string;
        }[];
      };
      mark_all_notifications_read: {
        Args: { p_business_id?: string };
        Returns: number;
      };
      order_purchase: { Args: { p_purchase_id: string }; Returns: undefined };
      platform_activate_subscription: {
        Args: {
          p_amount: number;
          p_business_id: string;
          p_event_id: string;
          p_months: number;
          p_plan_code: string;
          p_provider: string;
        };
        Returns: Json;
      };
      receive_purchase: { Args: { p_purchase_id: string }; Returns: undefined };
      record_customer_payment: {
        Args: {
          p_amount: number;
          p_customer_id: string;
          p_external_reference?: string;
          p_location_id: string;
          p_method: Database["public"]["Enums"]["payment_method"];
          p_note?: string;
        };
        Returns: string;
      };
      record_purchase_payment: {
        Args: {
          p_amount: number;
          p_external_reference?: string;
          p_location_id: string;
          p_method: Database["public"]["Enums"]["payment_method"];
          p_note?: string;
          p_purchase_id: string;
        };
        Returns: string;
      };
      remove_member: {
        Args: { p_business_id: string; p_user_id: string };
        Returns: undefined;
      };
      reply_support_ticket: {
        Args: { p_body: string; p_ticket_id: string };
        Returns: string;
      };
      save_purchase: {
        Args: {
          p_business_id: string;
          p_discount_amount?: number;
          p_items: Json;
          p_location_id: string;
          p_notes?: string;
          p_purchase_id: string;
          p_supplier_id: string;
          p_supplier_reference?: string;
        };
        Returns: string;
      };
      set_customer_credit_limit: {
        Args: { p_credit_limit: number; p_customer_id: string };
        Returns: undefined;
      };
      set_member_status: {
        Args: {
          p_business_id: string;
          p_status: Database["public"]["Enums"]["member_status"];
          p_user_id: string;
        };
        Returns: undefined;
      };
      set_product_status: {
        Args: {
          p_product_id: string;
          p_status: Database["public"]["Enums"]["record_status"];
        };
        Returns: undefined;
      };
      transfer_stock: {
        Args: {
          p_business_id: string;
          p_from_location_id: string;
          p_product_id: string;
          p_quantity: number;
          p_reason?: string;
          p_to_location_id: string;
        };
        Returns: string;
      };
    };
    Enums: {
      announcement_audience: "ALL" | "PLAN" | "BUSINESS" | "ROLE";
      announcement_status: "DRAFT" | "SENT";
      billing_period: "MONTHLY" | "YEARLY";
      business_status: "ACTIVE" | "SUSPENDED";
      customer_transaction_type:
        "CREDIT_SALE" | "PAYMENT" | "ADJUSTMENT" | "SALE_CANCELLATION";
      inventory_movement_type:
        | "INITIAL"
        | "PURCHASE"
        | "SALE"
        | "SALE_CANCELLATION"
        | "RETURN"
        | "ADJUSTMENT"
        | "TRANSFER_OUT"
        | "TRANSFER_IN"
        | "LOSS"
        | "DAMAGE";
      location_type: "STORE" | "WAREHOUSE";
      member_status: "INVITED" | "ACTIVE" | "SUSPENDED";
      notification_type:
        | "LOW_STOCK"
        | "LARGE_SALE"
        | "MEMBER_INVITED"
        | "SUBSCRIPTION"
        | "PAYMENT_RECEIVED"
        | "SYSTEM";
      payment_direction: "IN" | "OUT";
      payment_method:
        | "CASH"
        | "WAVE"
        | "ORANGE_MONEY"
        | "FREE_MONEY"
        | "CARD"
        | "BANK_TRANSFER"
        | "CHEQUE"
        | "OTHER";
      payment_status: "UNPAID" | "PARTIAL" | "PAID";
      platform_admin_status: "ACTIVE" | "SUSPENDED";
      platform_role:
        "SUPER_ADMIN" | "OPERATIONS" | "SUPPORT" | "FINANCE" | "ANALYST";
      purchase_status: "DRAFT" | "ORDERED" | "RECEIVED" | "CANCELLED";
      record_status: "ACTIVE" | "ARCHIVED";
      sale_status: "COMPLETED" | "CANCELLED";
      subscription_status:
        "TRIALING" | "ACTIVE" | "PAST_DUE" | "CANCELLED" | "EXPIRED";
      ticket_priority: "LOW" | "NORMAL" | "HIGH" | "URGENT";
      ticket_status: "OPEN" | "IN_PROGRESS" | "WAITING" | "RESOLVED" | "CLOSED";
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
};

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">;

type DefaultSchema = DatabaseWithoutInternals[Extract<
  keyof Database,
  "public"
>];

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R;
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R;
      }
      ? R
      : never
    : never;

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema["Tables"] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I;
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I;
      }
      ? I
      : never
    : never;

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    keyof DefaultSchema["Tables"] | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U;
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U;
      }
      ? U
      : never
    : never;

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    keyof DefaultSchema["Enums"] | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never;

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never;

export const Constants = {
  public: {
    Enums: {
      announcement_audience: ["ALL", "PLAN", "BUSINESS", "ROLE"],
      announcement_status: ["DRAFT", "SENT"],
      billing_period: ["MONTHLY", "YEARLY"],
      business_status: ["ACTIVE", "SUSPENDED"],
      customer_transaction_type: [
        "CREDIT_SALE",
        "PAYMENT",
        "ADJUSTMENT",
        "SALE_CANCELLATION",
      ],
      inventory_movement_type: [
        "INITIAL",
        "PURCHASE",
        "SALE",
        "SALE_CANCELLATION",
        "RETURN",
        "ADJUSTMENT",
        "TRANSFER_OUT",
        "TRANSFER_IN",
        "LOSS",
        "DAMAGE",
      ],
      location_type: ["STORE", "WAREHOUSE"],
      member_status: ["INVITED", "ACTIVE", "SUSPENDED"],
      notification_type: [
        "LOW_STOCK",
        "LARGE_SALE",
        "MEMBER_INVITED",
        "SUBSCRIPTION",
        "PAYMENT_RECEIVED",
        "SYSTEM",
      ],
      payment_direction: ["IN", "OUT"],
      payment_method: [
        "CASH",
        "WAVE",
        "ORANGE_MONEY",
        "FREE_MONEY",
        "CARD",
        "BANK_TRANSFER",
        "CHEQUE",
        "OTHER",
      ],
      payment_status: ["UNPAID", "PARTIAL", "PAID"],
      platform_admin_status: ["ACTIVE", "SUSPENDED"],
      platform_role: [
        "SUPER_ADMIN",
        "OPERATIONS",
        "SUPPORT",
        "FINANCE",
        "ANALYST",
      ],
      purchase_status: ["DRAFT", "ORDERED", "RECEIVED", "CANCELLED"],
      record_status: ["ACTIVE", "ARCHIVED"],
      sale_status: ["COMPLETED", "CANCELLED"],
      subscription_status: [
        "TRIALING",
        "ACTIVE",
        "PAST_DUE",
        "CANCELLED",
        "EXPIRED",
      ],
      ticket_priority: ["LOW", "NORMAL", "HIGH", "URGENT"],
      ticket_status: ["OPEN", "IN_PROGRESS", "WAITING", "RESOLVED", "CLOSED"],
    },
  },
} as const;
