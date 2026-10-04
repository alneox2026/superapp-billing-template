# SuperApp Central Billing API Service

Production-ready standalone **Billing & Stripe Integration Service** for the SuperApp ecosystem.

This service acts as the **single source of truth for payments, customer wallets, and Stripe subscriptions** across all 100+ agents and multiple Agent Middleware clusters.

---

## 🏛️ Architecture Overview

```
                        [ FlutterFlow Mobile / Web SuperApp ]
                                     │         │
             ┌───────────────────────┘         └─────────────────────────┐
             ▼ (Top-ups & Subscriptions)                                 ▼ (Chat & Streaming)
   ┌───────────────────────────┐                         ┌──────────────────────────────────┐
   │    CENTRAL BILLING API    │                         │     AGENT CLUSTER MIDDLEWARES    │
   │  (This Standalone Svc)    │                         │  - Gateway Cloud Run             │
   │  - Stripe Checkout        │                         │  - Persistence Worker Cloud Run  │
   │  - 1 Stripe Webhook       │                         └─────────────────┬────────────────┘
   │  - 1 Reconciler Scheduler │                                           │
   └─────────────┬─────────────┘                                           ▼
                 │                                       ┌──────────────────────────────────┐
                 │                                       │   OTHER AGENT CLUSTER (1..N)     │
                 │                                       │  - Gateway Cloud Run             │
                 │                                       │  - Persistence Worker Cloud Run  │
                 │                                       └─────────────────┬────────────────┘
                 ▼                                                         │
   ════════════════════════════════════════════════════════════════════════▼═════════════════
                                   SHARED FIRESTORE DATABASE
     • customer_wallets_v3          (GLOBAL: 1 wallet per user across all agents)
     • customer_billing_accounts_v3 (GLOBAL: 1 Stripe customer per user)
     • stripe_webhook_events_v3     (GLOBAL: Webhook idempotency)
     • subscription_cancellation... (GLOBAL: Pending cancellations)
   ══════════════════════════════════════════════════════════════════════════════════════════
```

### Key Architectural Benefits:
1. **Single Stripe Webhook:** Exactly one webhook URL registered in the Stripe Dashboard. Zero webhook limits or multi-service collision issues.
2. **Strict Security Isolation:** Only this service's service account (`superapp-billing-sa`) has IAM permissions to access Stripe secret keys. Agent clusters have zero access to Stripe credentials.
3. **Decoupled Agent Clusters:** Agent middleware clusters reserve and settle credits directly via Firestore transactions. They never make synchronous HTTP calls to the Billing API during chat.

---

## 🚀 API Endpoints

### 1. FlutterFlow App Facing (Authenticated via Firebase Auth)
* `POST /v1/billing/topups/checkout-session`: Generates a Stripe Checkout URL for prepaid credit top-up packages (e.g. $5, $10, $25) or starts the monthly platform fee subscription.
* `GET /ready` & `GET /health`: Health checks.

### 2. Stripe Facing (Authenticated via Stripe Signature)
* `POST /v1/billing/stripe/webhook`: Receives and processes the canonical 9 Stripe events:
  - `checkout.session.completed`: Credits user wallet in Firestore upon immediate payment.
  - `checkout.session.async_payment_succeeded`: Credits user wallet when delayed payment methods (e.g. ACH, SEPA) settle.
  - `invoice.paid`: Settles recurring monthly platform service fee and advances customer billing period.
  - `invoice.payment_failed`: Records subscription payment failure for grace-period handling.
  - `customer.subscription.updated`: Syncs active/past_due subscription status changes.
  - `customer.subscription.deleted`: Revokes subscription benefits upon cancellation or non-payment.
  - `refund.created`: Debits wallet for refunded token packages.
  - `charge.dispute.created`: Records dispute holds and audit trail.
  - `charge.dispute.closed`: Settles dispute outcome (won/lost).

> [!NOTE]
> **Event Dispatch & Pre-Dispatch Validation**:
> - **Canonical 9 Events**: The service explicitly handles the 9 events listed above. `customer.subscription.created` is **not** one of the configured events, and the service does not treat it as a subscription-state event. If a valid, matching-environment event of that type is delivered anyway, it reaches the `_record_ignored_event` fallback path and is recorded idempotently in `stripe_webhook_events_v3` with outcome `"ignored"` (returning `200 OK` to Stripe without mutating subscription state).
> - **Pre-Dispatch Rejection vs. Ignored Events**: Events only reach the ignored-event path if they pass pre-dispatch validation:
>   1. The endpoint strictly validates the `Stripe-Signature` header (`BillingApiError(400, "stripe_signature_invalid")`).
>   2. The endpoint verifies that the event's `livemode` matches the configured catalog environment (`BillingApiError(400, "stripe_environment_mismatch")`).
>   Invalid signatures and mode mismatches are actively rejected with HTTP 400, **not** ignored. Furthermore, unexpected Firestore transaction failures or processing exceptions will fail with 5xx to trigger Stripe delivery retries.

### 3. Internal Automation (Authenticated via Cloud Run OIDC)
* `POST /v1/billing/internal/cancellation/reconcile`: Cloud Scheduler endpoint that reconciles pending Stripe subscription cancellations every hour.

---

## 🔐 Secret Management (Secret Manager)

The billing service relies on two secrets in Google Secret Manager. Because registering a Stripe webhook endpoint requires the deployed Cloud Run URL, deployment follows a **two-phase bootstrap sequence**:

1. **Phase 1 (Pre-Deployment)**: `stripe-secret-key` is **mandatory** before initial deployment.
2. **Phase 2 (Post-Deployment)**: `stripe-webhook-signing-secret` is created **after** the initial deploy once the Cloud Run service URL is known and registered in Stripe.

To prevent secrets from being recorded in your terminal shell history, use `read -s` instead of inline `echo`:

### Phase 1: Stripe Secret Key (Required Before Initial Deploy)

#### Option A: Create New Secret (Initial Setup, Version 1)
If the secret does not exist yet in your GCP project:
```bash
read -s -p "Enter Stripe Secret Key: " STRIPE_KEY
echo -n "$STRIPE_KEY" | gcloud secrets create stripe-secret-key --data-file=-
unset STRIPE_KEY
```

#### Option B: Rotate Existing Secret (Adding a New Version)
If `stripe-secret-key` already exists in your GCP project, add a new version:
```bash
read -s -p "Enter New Secret Key: " STRIPE_KEY
echo -n "$STRIPE_KEY" | gcloud secrets versions add stripe-secret-key --data-file=-
unset STRIPE_KEY
```
Note the version number printed in the output (e.g. `Created version [3]`). Export that specific secret's version before deploying:
```bash
export STRIPE_SECRET_KEY_SECRET_VERSION="3"
```

---

### Phase 2: Stripe Webhook Signing Secret (Created After Initial Deploy)
Once Cloud Run is initially deployed and you have registered `https://<billing_api_url>/v1/billing/stripe/webhook` in the Stripe Dashboard, Stripe generates a signing secret (`whsec_...`).

#### Option A: Create New Secret (Initial Setup, Version 1)
```bash
read -s -p "Enter Stripe Webhook Signing Secret: " STRIPE_WHSEC
echo -n "$STRIPE_WHSEC" | gcloud secrets create stripe-webhook-signing-secret --data-file=-
unset STRIPE_WHSEC
```

#### Option B: Rotate Existing Secret (Adding a New Version)
If `stripe-webhook-signing-secret` already exists in your GCP project, add a new version:
```bash
read -s -p "Enter New Webhook Signing Secret: " STRIPE_WHSEC
echo -n "$STRIPE_WHSEC" | gcloud secrets versions add stripe-webhook-signing-secret --data-file=-
unset STRIPE_WHSEC
```
Note the version number printed in the output (e.g. `Created version [2]`). Export that specific secret's version before deploying:
```bash
export STRIPE_WEBHOOK_SIGNING_SECRET_VERSION="2"
```

> [!IMPORTANT]
> **Terraform Secret Version Pinning**:
> By default, Terraform pins Cloud Run secret mounts to version `"1"`.
> - If you created fresh secrets via Option A, both are version `"1"`, so no version overrides are needed.
> - If you rotated an existing secret via Option B, **do not assume both secrets share the same version number**—their versions can differ depending on rotation history. Set each override to the **actual version number** for that specific secret (for example, API key `3`, webhook secret `2`):
>   ```bash
>   export STRIPE_SECRET_KEY_SECRET_VERSION="3"
>   export STRIPE_WEBHOOK_SIGNING_SECRET_VERSION="2"
>   ```

---

## 🛠️ Deployment via Google Cloud Shell

### Step 1: Build the Container Image
```bash
export PROJECT_ID="ceo-dev123"
export REGION="us-central1"
./scripts/cloudshell_build_billing.sh
```

### Step 2: Initial Deploy (Bootstrap Without Webhook Secret)
The initial deployment provisions the Cloud Run service, IAM roles, and Firestore collections without requiring a webhook signing secret:
```bash
export PROJECT_ID="ceo-dev123"
export REGION="us-central1"
# Ensure STRIPE_WEBHOOK_SIGNING_SECRET_ID is empty/unset for initial deploy
unset STRIPE_WEBHOOK_SIGNING_SECRET_ID
./scripts/cloudshell_deploy_billing.sh
```
At the end of deployment, Terraform prints `billing_api_url` (e.g., `https://superapp-billing-api-xyz-uc.a.run.app`).

### Step 3: Register Webhook in Stripe & Redeploy
1. In your **Stripe Dashboard > Developers > Webhooks**, create an endpoint pointing to `https://<billing_api_url>/v1/billing/stripe/webhook` and subscribe to the canonical 9 events.
2. Stripe will provide a signing secret (`whsec_...`). Store it in Secret Manager as shown in [Phase 2 above](#phase-2-stripe-webhook-signing-secret-created-after-initial-deploy).
3. Redeploy with the webhook secret ID attached (along with each secret's actual version if rotated):
```bash
export STRIPE_WEBHOOK_SIGNING_SECRET_ID="stripe-webhook-signing-secret"
# If secrets were rotated, export each secret's actual version:
# export STRIPE_SECRET_KEY_SECRET_VERSION="3"
# export STRIPE_WEBHOOK_SIGNING_SECRET_VERSION="2"
./scripts/cloudshell_deploy_billing.sh
```

---

## 🚀 Production Go-Live Checklist

Follow this checklist before approving and executing a live production rollout:

1. **GCP Project Isolation**:
   * Set your active production Google Cloud Project:
     ```bash
     gcloud config set project <PRODUCTION_PROJECT_ID>
     export PROJECT_ID="<PRODUCTION_PROJECT_ID>"
     ```
   * Confirm that the deploy script banner prints `<PRODUCTION_PROJECT_ID>` and not `ceo-dev123`. Do not use `ALLOW_DEV_PROJECT_IN_PROD=true`.

2. **Browser Origins (CORS)**:
   * Export your exact production domain(s) as a plain string without markdown formatting:
     ```bash
     export ALLOWED_ORIGINS="https://app.yourdomain.com"
     # Multiple origins: export ALLOWED_ORIGINS="https://app.yourdomain.com,https://admin.yourdomain.com"
     ```

3. **Stripe Checkout Return URLs**:
   * Set your real client application redirect URLs so users return to your web/mobile app rather than `example.com` after completing or cancelling Stripe Checkout:
     ```bash
     export CHECKOUT_SUCCESS_URL="https://app.yourdomain.com/billing/success?session_id={CHECKOUT_SESSION_ID}"
     export CHECKOUT_CANCEL_URL="https://app.yourdomain.com/billing/cancel"
     ```

4. **Live Stripe Catalog & Credentials**:
   * In your **Stripe Live Dashboard**, create the corresponding top-up packages ($5, $10, $25) and monthly recurring subscription fee.
   * Update `config/billing.prod.yaml`:
     - Change `stripe_mode: test` to `stripe_mode: live`.
     - Replace each `price_...` placeholder with the real live Stripe Price IDs.
   * Securely store your live Stripe restricted key (`rk_live_...`) in Secret Manager without shell history leakage:
     - **If creating a new secret:**
       ```bash
       read -s -p "Enter Live Stripe Secret Key: " STRIPE_KEY
       echo -n "$STRIPE_KEY" | gcloud secrets create stripe-secret-key --data-file=-
       unset STRIPE_KEY
       ```
     - **If rotating an existing secret (adding a new version):**
       ```bash
       read -s -p "Enter Live Stripe Secret Key: " STRIPE_KEY
       echo -n "$STRIPE_KEY" | gcloud secrets versions add stripe-secret-key --data-file=-
       unset STRIPE_KEY
       ```
       Note the resulting version number printed by `gcloud` (e.g. `Created version [3]`). Export that secret's actual version override before deploying:
       ```bash
       export STRIPE_SECRET_KEY_SECRET_VERSION="3"
       ```

5. **Live Stripe Webhook Destination**:
   * **Important**: Do not route end-user traffic to the billing service until the webhook signing secret is configured. Without it, the webhook handler returns `503 stripe_webhook_not_configured`.
   * Deploy the service initially without the webhook signing secret:
     ```bash
     export DEPLOYMENT_ENV="production"
     unset STRIPE_WEBHOOK_SIGNING_SECRET_ID
     ./scripts/cloudshell_deploy_billing.sh
     ```
   * Copy the output `billing_api_url` and register a live endpoint in your **Stripe Live Dashboard > Developers > Webhooks**:
     `https://<billing_api_url>/v1/billing/stripe/webhook`
     Subscribing to these exact 9 events:
     - `charge.dispute.closed`
     - `charge.dispute.created`
     - `checkout.session.async_payment_succeeded`
     - `checkout.session.completed`
     - `customer.subscription.deleted`
     - `customer.subscription.updated`
     - `invoice.paid`
     - `invoice.payment_failed`
     - `refund.created`
   * Securely store the live webhook signing secret (`whsec_...`) in Secret Manager:
     - **If creating a new secret:**
       ```bash
       read -s -p "Enter Live Stripe Webhook Signing Secret: " STRIPE_WHSEC
       echo -n "$STRIPE_WHSEC" | gcloud secrets create stripe-webhook-signing-secret --data-file=-
       unset STRIPE_WHSEC
       ```
     - **If rotating an existing secret (adding a new version):**
       ```bash
       read -s -p "Enter Live Stripe Webhook Signing Secret: " STRIPE_WHSEC
       echo -n "$STRIPE_WHSEC" | gcloud secrets versions add stripe-webhook-signing-secret --data-file=-
       unset STRIPE_WHSEC
       ```
       Note the resulting version number printed by `gcloud` (e.g. `Created version [2]`). Export that secret's actual version override before deploying:
       ```bash
       export STRIPE_WEBHOOK_SIGNING_SECRET_VERSION="2"
       ```

   * Redeploy passing `STRIPE_WEBHOOK_SIGNING_SECRET_ID="stripe-webhook-signing-secret"` (and set each override to the actual version if rotated):
     ```bash
     export STRIPE_WEBHOOK_SIGNING_SECRET_ID="stripe-webhook-signing-secret"
     # If secrets were rotated, export each secret's actual version (numbers may differ):
     # export STRIPE_SECRET_KEY_SECRET_VERSION="3"
     # export STRIPE_WEBHOOK_SIGNING_SECRET_VERSION="2"
     ./scripts/cloudshell_deploy_billing.sh
     ```
   * **Webhook Verification & Dispatch Qualification**:
     - Signature verification and Stripe-mode validation happen before event dispatch. Invalid signatures fail with `400 stripe_signature_invalid`, and mode mismatches fail with `400 stripe_environment_mismatch` (e.g. synthetic test events sent against a `stripe_mode: live` deployment). These are actively rejected, not ignored.
     - If a valid, matching-environment event of an unconfigured type (such as `customer.subscription.created`) is delivered, it falls through to `_record_ignored_event` and is recorded idempotently in `stripe_webhook_events_v3` with outcome `"ignored"` (`200 OK` response with no billing state mutation).
     - Any Firestore transaction or processing failures will return 5xx errors so Stripe can retry.
     - Verify the live endpoint status directly in the Stripe Live Dashboard, or test synthetic flows against your staging deployment (`stripe_mode: test`).

6. **Manual Terraform Review**:
   * Ensure `TERRAFORM_AUTO_APPROVE` is unset or `false`.
   * Manually review the output plan in Cloud Shell, verify resource names and IAM roles, then type `yes` when prompted.

---

## 🧪 Local Testing

Run all unit and integration tests:
```bash
python -m pytest -q
```
All tests use fakes and mocks; no live Stripe or GCP connection is required.
