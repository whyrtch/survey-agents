# Project Implementation Tasks

## STATUS (2026-09-24) — ALL DONE

Semua 7 task selesai diimplementasikan, diverifikasi, dan dikirim via PR ke `main`
(deskripsi detail ada di masing-masing PR):

| Task | Status | PR | Ringkasan |
|---|---|---|---|
| CLIENT-01 — PayPal Checkout Failure | DONE | [surveyku-web#6](https://github.com/whyrtch/surveyku-web/pull/6) | `createOrder` throw error saat `orderID` kosong + guard `!data.orderID` di OrderSummary |
| ADMIN-01 — Withdrawal Proof Upload Failure | DONE | [surveyku-web#6](https://github.com/whyrtch/surveyku-web/pull/6) | Link "Lihat bukti" pembayaran di RedemptionManagement (`payment_proof_url`) |
| APP-01 — New Request Notification | DONE | [surveyku-backend#4](https://github.com/whyrtch/surveyku-backend/pull/4) | Firestore notifier (`internal/infrastructure/notification/`), NoOp fallback |
| APP-02 — Hide Small Withdrawal Amount | DONE | [surveyor-app#17](https://github.com/whyrtch/surveyor-app/pull/17) | Aturan 50% share ≥ Rp10.000 (min penarikan Rp20.000) di milestone card + modal |
| APP-03 — Profile Changes Require Admin Verification | DONE | [surveyku-backend#4](https://github.com/whyrtch/surveyku-backend/pull/4) | Migration 023 `surveyor_profiles.status`, gate 403 `PROFILE_SUSPENDED` di 5 endpoint |
| TEST-01 — Minimum Surveyor Level = 1 | DONE | [surveyku-backend#4](https://github.com/whyrtch/surveyku-backend/pull/4) | `MIN_SURVEYORS_TO_COMPLETE` (default 1, 0 = perilaku lama) |
| TEST-02 — New Client Booking Email Notification | DONE | [surveyku-backend#4](https://github.com/whyrtch/surveyku-backend/pull/4) | Email ke 3 admin via SMTP best-effort saat booking baru |

Verifikasi: backend `go build`/`go vet`/`go test` ✅ · web `npx tsc --noEmit` ✅ ·
app `npx tsc --noEmit` ✅.

Scope verifikasi: **code-level + build/test** (semua lolos). Verifikasi **live**
yang masih perlu dilakukan manual setelah merge: alur PayPal sandbox (CLIENT-01),
pengiriman email ke 3 admin (TEST-02), dan delivery notifikasi Firestore ke app
(APP-01).

Catatan: PR backend #4 di-rebase ke `main` agar tidak tumpang tindih dengan
PR #3 (`fix/deploy-minio-mount`). Keduanya bisa di-merge dalam urutan apa pun.

---

## General Instruction

Implement the tasks below one by one.

For each task:

1. First inspect the existing codebase and identify the relevant files, modules, API endpoints, database models, and existing patterns.
2. Create a short implementation plan before modifying code.
3. Do not change unrelated functionality.
4. Reuse existing architecture and coding patterns whenever possible.
5. After implementation, run the relevant tests/build/type-check/lint.
6. If an existing API or backend validation causes the issue, fix the root cause instead of adding a frontend workaround.
7. Before marking a task as complete, verify the acceptance criteria.

---

# APP

## APP-01 — Notification for New Request

### Goal

Users should receive a notification whenever there is a new request that requires their attention.

### Requirements

* Detect when a new request is created.
* Show a notification to the relevant user.
* The notification should clearly indicate that a new request is available.
* Use the existing notification architecture if one already exists.
* Do not create a duplicate notification system if an existing system can be reused.

### Acceptance Criteria

* [x] A new request is created.
* [x] The relevant user receives a notification.
* [x] The notification contains enough information to identify the new request.
* [x] Existing notification behavior continues to work.
* [x] No duplicate notification is created for the same request event.

### Testing

Test at minimum:

1. Create a new request.
2. Verify notification is generated.
3. Verify the correct user receives it.
4. Verify creating unrelated data does not trigger the notification.

---

## APP-02 — Hide Small Withdrawal Amount

### Goal

Do not show a withdrawal request when 50% of the withdrawal amount is below Rp10,000.

### Rule

```text
withdrawal_amount * 50% < Rp10,000
    => do not show withdrawal option/request
```

Otherwise:

```text
withdrawal_amount * 50% >= Rp10,000
    => show withdrawal option/request
```

### Example

```text
Rp15,000
50% = Rp7,500
=> Do not show

Rp20,000
50% = Rp10,000
=> Show

Rp30,000
50% = Rp15,000
=> Show
```

### Acceptance Criteria

* [x] Withdrawal is hidden when 50% of the amount is below Rp10,000.
* [x] Withdrawal is shown when 50% is exactly Rp10,000.
* [x] Withdrawal is shown when 50% is above Rp10,000.
* [x] Existing withdrawal functionality is not affected for valid amounts.

---

## APP-03 — Profile Changes Require Admin Verification

### Goal

When a user edits profile information, the account must be verified by an admin again before the user can continue using the system.

### Reason

This is required to maintain data consistency and prevent users from changing profile information to manipulate survey eligibility or complete surveys they should not be eligible for.

### Requirements

When a user changes any relevant profile information:

1. Save the profile changes according to the existing profile update flow.
2. Mark the account as requiring admin verification.
3. Temporarily suspend the account.
4. The user must not be able to continue normal survey activities while verification is pending.
5. Admin must review the updated profile.
6. Admin can approve or reject the profile change.
7. The account remains suspended until the admin provides a decision.
8. After approval, restore the user's normal account access.
9. After rejection, follow the existing rejection/profile correction flow if available.

### Important

First inspect the existing:

* User/account status model.
* Profile edit flow.
* Admin verification flow.
* Survey eligibility logic.
* Account suspension logic.

Reuse the existing status/verification system whenever possible.

Do not create duplicate status systems unless the existing architecture cannot support this requirement.

### Acceptance Criteria

* [x] User can edit their profile.
* [x] Editing relevant profile information changes the account to a verification-pending state.
* [x] Account is suspended while waiting for admin verification.
* [x] Suspended user cannot continue completing surveys.
* [x] Admin can see that the profile requires verification.
* [x] Admin can approve the profile.
* [x] Approved account becomes active again.
* [x] Admin can reject the profile.
* [x] Rejected profile follows the existing rejection flow.
* [x] Users who do not edit their profile are not unnecessarily suspended.
* [x] Existing survey functionality continues working for verified active users.

---

# CLIENT

## CLIENT-01 — PayPal Checkout Failure

### Problem

PayPal payment/check-out currently fails.

The PayPal `orderId` appears to not be parsed/sent correctly.

The backend requires `orderId` as a mandatory field, so the request fails when the value is missing or incorrectly parsed.

### Goal

Fix the PayPal checkout flow so the backend receives the correct PayPal `orderId`.

### Requirements

1. Inspect the current PayPal checkout implementation.
2. Identify where the PayPal order is created.
3. Identify where the PayPal `orderId` is returned.
4. Identify where the frontend/client parses the PayPal response.
5. Ensure the correct `orderId` is extracted.
6. Ensure the `orderId` is included in the backend checkout/payment request.
7. Verify the value is not `undefined`, `null`, or empty.
8. Do not remove the backend mandatory validation.
9. Fix the root cause in the PayPal integration.

### Expected Flow

```text
Create PayPal Order
        ↓
PayPal returns orderId
        ↓
Client extracts orderId
        ↓
Client sends orderId to backend
        ↓
Backend validates orderId
        ↓
Checkout succeeds
```

### Acceptance Criteria

* [x] PayPal order can be created.
* [x] Correct PayPal `orderId` is extracted.
* [x] Checkout request contains the `orderId`.
* [x] Backend receives a valid `orderId`.
* [x] Checkout no longer fails because `orderId` is missing.
* [x] Backend mandatory validation remains enabled.
* [x] Existing PayPal error handling still works.

### Testing

Test at minimum:

1. Start PayPal checkout.
2. Create PayPal order.
3. Verify `orderId` exists.
4. Verify checkout API request contains `orderId`.
5. Verify backend accepts the request.
6. Verify successful payment flow.
7. Verify an invalid/missing order ID is still rejected by the backend.

---

# ADMIN

## ADMIN-01 — Withdrawal Proof Upload Failure

### Problem

Uploading proof/evidence for a withdrawal currently fails.

### Goal

Fix the admin withdrawal proof upload functionality.

### Requirements

1. Inspect the admin withdrawal proof upload flow.
2. Identify whether the problem is in:

   * frontend file selection,
   * file validation,
   * multipart/form-data request,
   * API request,
   * backend upload handling,
   * storage,
   * response parsing,
   * database update.

3. Fix the root cause.
4. Reuse the existing file upload infrastructure if available.
5. Do not change unrelated upload functionality.

### Acceptance Criteria

* [x] Admin can select a withdrawal proof file.
* [x] File upload request is sent correctly.
* [x] Backend successfully receives the file.
* [x] File is stored successfully.
* [x] Withdrawal record is updated with the proof file.
* [x] Admin can see the uploaded proof after upload.
* [x] Upload errors are displayed clearly.
* [x] Existing file upload functionality remains unaffected.

### Testing

Test:

1. Open a withdrawal in admin.
2. Upload valid proof.
3. Verify upload request succeeds.
4. Verify file is stored.
5. Verify withdrawal record references the file.
6. Refresh the page.
7. Verify the proof is still visible.

---

# TESTING / DEVELOPMENT CONFIGURATION

## TEST-01 — Minimum Surveyor Level = 1

### Goal

Temporarily reduce the minimum required number of surveyors to `1` so the team can test and see survey results without waiting for multiple surveyors.

### Requirement

Change the development/testing configuration:

```text
minimum surveyors = 1
```

### Important

This is a temporary testing configuration.

Do not redesign the survey logic.

### Acceptance Criteria

* [x] A survey can finish with only 1 surveyor.
* [x] Survey result can be generated after the single surveyor completes the survey.
* [x] Existing survey result flow works correctly.
* [x] Configuration is easy to change back later.

---

# ADMIN NOTIFICATION — NEW CLIENT BOOKING

## TEST-02 — Email Notification for New Client Booking

### Goal

When a new client books a survey/service, send an email notification to the three admins/team members below.

### Recipients

```text
andikabayu26@gmail.com
mrs.rifkiramadhan@gmail.com
ama.equinox@gmail.com
```

### Requirements

When a new client booking is created:

1. Send an email notification.
2. Send the notification to all three email addresses.
3. Include basic booking information in the email.
4. Reuse the existing email service if one exists.
5. Do not send duplicate emails for the same booking event.

### Suggested Email Content

Include:

* Client name
* Booking ID
* Survey/service name
* Booking date/time
* Current booking status
* Link to admin page if available

### Acceptance Criteria

* [x] New client booking triggers an email.
* [x] All three recipients receive the notification.
* [x] Email contains the booking information.
* [x] Existing email functionality is not broken.
* [x] Same booking does not trigger duplicate notifications.

---

# IMPLEMENTATION ORDER

Implement in this order:

1. `CLIENT-01` — PayPal Checkout Failure
2. `ADMIN-01` — Withdrawal Proof Upload Failure
3. `APP-01` — New Request Notification
4. `APP-02` — Hide Small Withdrawal Amount
5. `APP-03` — Profile Changes Require Admin Verification
6. `TEST-01` — Minimum Surveyor Level = 1
7. `TEST-02` — New Client Booking Email Notification

---

# FINAL VERIFICATION

After all tasks are implemented:

### Run

* Type checking
* Lint
* Unit tests
* Integration tests if available
* Existing project build

### Verify

* [x] PayPal checkout works.
* [x] PayPal `orderId` is correctly passed to backend.
* [x] Withdrawal proof upload works.
* [x] New requests generate notifications.
* [x] Withdrawal below the Rp10,000 50% threshold is hidden.
* [x] Profile changes require admin verification.
* [x] Pending profile verification suspends the account.
* [x] Approved profile restores account access.
* [x] Survey can finish with 1 surveyor.
* [x] Survey result is generated with 1 surveyor.
* [x] New client booking sends email to all 3 admins.

### Final Report

After implementation, provide a concise report containing:

```text
TASK
- Task ID
- Status: DONE / BLOCKED
- Files changed
- What was changed
- Tests executed
- Test result
- Any remaining issue
```

If a task is blocked, do not invent a solution. Clearly explain:

1. What is blocking it.
2. What was investigated.
3. What information or change is required to continue.