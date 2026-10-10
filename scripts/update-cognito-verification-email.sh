#!/usr/bin/env bash
# Configure the Azentz Cognito verification email.
# Paths are resolved from this file, not from the current working directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# GitHub Actions supplies short-lived credentials in the environment. A named
# profile exists only for a local run.
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  PROFILE="${AWS_PROFILE:-}"
else
  PROFILE="${AWS_PROFILE:-azentz}"
fi
REGION="${AWS_REGION:-ap-south-1}"
USER_POOL_ID="${COGNITO_USER_POOL_ID:-ap-south-1_KqqgVA9rC}"

EMAIL_FROM="Azentz <kindlydonotreply@azentz.com>"
SES_SOURCE_ARN="arn:aws:ses:ap-south-1:452408358532:identity/azentz.com"
EMAIL_SUBJECT="Your Azentz verification code"
LOGO_URL="https://azentz-assets.pages.dev/email/azentz-logo-transparent.png"
LOCAL_LOGO="${CONFIG_DIR}/email/azentz-logo-transparent.png"
HTML_FILE="${CONFIG_DIR}/email/verification.html"

MODE="update"
if [[ "${1:-}" == "--check" ]]; then
  MODE="check"
elif [[ "${1:-}" == "--validate" ]]; then
  MODE="validate"
elif [[ $# -gt 0 ]]; then
  echo "ERROR: Unknown argument: $1" >&2
  echo "Usage: $0 [--check|--validate]" >&2
  exit 1
fi

aws_az() {
  if [[ -n "${PROFILE}" ]]; then
    aws "$@" --profile "${PROFILE}" --region "${REGION}"
  else
    aws "$@" --region "${REGION}"
  fi
}

file_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

export AWS_PAGER=""
export AZENTZ_HTML_SOURCE="${HTML_FILE}"
export AZENTZ_EMAIL_SUBJECT="${EMAIL_SUBJECT}"
export AZENTZ_EMAIL_FROM="${EMAIL_FROM}"
export AZENTZ_SES_SOURCE_ARN="${SES_SOURCE_ARN}"
export AZENTZ_LOGO_URL="${LOGO_URL}"
export AZENTZ_USER_POOL_ID="${USER_POOL_ID}"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/azentz-cognito-email.XXXXXX")"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

VERIFICATION_JSON="${TMP_DIR}/verification-message-template.json"
EMAIL_JSON="${TMP_DIR}/email-configuration.json"
DESCRIBE_BEFORE="${TMP_DIR}/describe-before.json"
UPDATE_JSON="${TMP_DIR}/update-user-pool.json"
DESCRIBE_AFTER="${TMP_DIR}/describe-after.json"
RESOLVED_HTML="${TMP_DIR}/verification-resolved.html"

export AZENTZ_HTML_FILE="${RESOLVED_HTML}"
export AZENTZ_COPYRIGHT_YEAR="$(TZ=Asia/Kolkata date +%Y)"
export AZENTZ_VERIFICATION_JSON="${VERIFICATION_JSON}"
export AZENTZ_EMAIL_JSON="${EMAIL_JSON}"
export AZENTZ_DESCRIBE_BEFORE="${DESCRIBE_BEFORE}"
export AZENTZ_UPDATE_JSON="${UPDATE_JSON}"
export AZENTZ_DESCRIBE_AFTER="${DESCRIBE_AFTER}"

echo "========================================"
echo " Azentz Cognito Email Configuration"
echo "========================================"
echo
echo "AWS Profile:"
if [[ -n "${PROFILE}" ]]; then
  echo "  ${PROFILE}"
else
  echo "  ambient credentials"
fi
echo "AWS Region:"
echo "  ${REGION}"
echo "User Pool:"
echo "  ${USER_POOL_ID}"
echo "Template:"
echo "  ${HTML_FILE}"
echo "Copyright year:"
echo "  ${AZENTZ_COPYRIGHT_YEAR} (Asia/Kolkata)"
echo "SES Source ARN:"
echo "  ${SES_SOURCE_ARN}"
echo "From:"
echo "  ${EMAIL_FROM}"
echo

if [[ ! -f "${HTML_FILE}" ]]; then
  echo "ERROR: HTML template not found:" >&2
  echo "  ${HTML_FILE}" >&2
  echo "Expected the template next to this config directory:" >&2
  echo "  ${CONFIG_DIR}/email/verification.html" >&2
  exit 1
fi

echo "Validating HTML template..."
node <<'NODE'
const fs = require("fs");

const htmlFile = process.env.AZENTZ_HTML_SOURCE;
const resolvedFile = process.env.AZENTZ_HTML_FILE;
const copyrightYear = process.env.AZENTZ_COPYRIGHT_YEAR;
const subject = process.env.AZENTZ_EMAIL_SUBJECT;
const from = process.env.AZENTZ_EMAIL_FROM;
const sourceArn = process.env.AZENTZ_SES_SOURCE_ARN;
const logoUrl = process.env.AZENTZ_LOGO_URL;
const verificationJson = process.env.AZENTZ_VERIFICATION_JSON;
const emailJson = process.env.AZENTZ_EMAIL_JSON;
const limit = 20000;

const source = fs.readFileSync(htmlFile, "utf8");

function fail(message) {
  console.error(`ERROR: ${message}`);
  console.error(`  ${htmlFile}`);
  process.exit(1);
}

if (!/^\d{4}$/.test(copyrightYear || "")) {
  fail(`Copyright year must be four digits. Received ${JSON.stringify(copyrightYear || "")}.`);
}
if (source.trim().length === 0) {
  fail("HTML template is empty.");
}
if (!source.includes("{####}")) {
  fail("HTML template must contain the Cognito placeholder {####}.");
}
if (!source.includes("{{year}}")) {
  fail("HTML template must contain {{year}} so the copyright year is inserted at publish time.");
}
if (!source.includes(logoUrl)) {
  fail(`HTML template is missing the Azentz logo URL: ${logoUrl}`);
}

const html = source.replaceAll("{{year}}", copyrightYear);
if (html.includes("{{year}}")) {
  fail("Copyright year placeholder was not replaced.");
}
const bytes = Buffer.byteLength(html, "utf8");
if (bytes > limit) {
  fail(`HTML template is ${bytes} UTF-8 bytes. Cognito allows at most ${limit}.`);
}
fs.writeFileSync(resolvedFile, html);

const verification = {
  DefaultEmailOption: "CONFIRM_WITH_CODE",
  EmailSubject: subject,
  EmailMessage: html
};
const email = {
  EmailSendingAccount: "DEVELOPER",
  SourceArn: sourceArn,
  From: from
};

fs.writeFileSync(verificationJson, JSON.stringify(verification, null, 2));
fs.writeFileSync(emailJson, JSON.stringify(email, null, 2));

console.log(`  Placeholder {####}: present`);
console.log(`  Copyright year: ${copyrightYear}`);
console.log(`  Logo URL: present`);
console.log(`  Template size: ${bytes} UTF-8 bytes (limit ${limit})`);
NODE

verify_logo() {
  echo
  echo "Checking the public logo matches the transparent wordmark..."
  if [[ ! -f "${LOCAL_LOGO}" ]]; then
    echo "ERROR: Transparent logo file not found:" >&2
    echo "  ${LOCAL_LOGO}" >&2
    exit 1
  fi
  LOGO_BODY="${TMP_DIR}/logo.png"
  LOGO_HEADERS="${TMP_DIR}/logo-headers.txt"
  LOGO_STATUS="$(curl -sS -D "${LOGO_HEADERS}" -o "${LOGO_BODY}" -w "%{http_code}" "${LOGO_URL}")"
  if [[ "${LOGO_STATUS}" != "200" ]]; then
    echo "ERROR: Logo URL returned HTTP ${LOGO_STATUS}." >&2
    echo "  ${LOGO_URL}" >&2
    echo "Cognito was not modified. Publish the transparent logo before applying this template." >&2
    exit 1
  fi
  if ! grep -qi '^content-type:[[:space:]]*image/png' "${LOGO_HEADERS}"; then
    echo "ERROR: Logo URL did not return image/png." >&2
    echo "  ${LOGO_URL}" >&2
    exit 1
  fi
  LOCAL_SHA="$(file_sha256 "${LOCAL_LOGO}")"
  REMOTE_SHA="$(file_sha256 "${LOGO_BODY}")"
  if [[ "${LOCAL_SHA}" != "${REMOTE_SHA}" ]]; then
    echo "ERROR: Public logo does not match ${LOCAL_LOGO}." >&2
    echo "  local  ${LOCAL_SHA}" >&2
    echo "  remote ${REMOTE_SHA}" >&2
    echo "Cognito was not modified." >&2
    exit 1
  fi
  echo "  HTTP 200 image/png"
  echo "  SHA-256 matches the transparent wordmark"
}

if [[ "${MODE}" == "validate" ]]; then
  verify_logo
  echo
  echo "Template validation passed. Cognito was not contacted."
  exit 0
fi

echo
echo "Checking AWS CLI identity..."
aws_az sts get-caller-identity --output json

echo
echo "Reading current user pool configuration..."
aws_az cognito-idp describe-user-pool \
  --user-pool-id "${USER_POOL_ID}" \
  --output json > "${DESCRIBE_BEFORE}"

node <<'NODE'
const fs = require("fs");
const pool = JSON.parse(fs.readFileSync(process.env.AZENTZ_DESCRIBE_BEFORE, "utf8")).UserPool || {};
const email = pool.EmailConfiguration || {};
const template = pool.VerificationMessageTemplate || {};
const attrs = pool.AutoVerifiedAttributes || [];
const message = template.EmailMessage || "";
console.log("Current relevant configuration:");
console.log(`  Pool name: ${pool.Name || ""}`);
console.log(`  AutoVerifiedAttributes: ${JSON.stringify(attrs)}`);
console.log(`  EmailSendingAccount: ${email.EmailSendingAccount || ""}`);
console.log(`  SourceArn: ${email.SourceArn || ""}`);
console.log(`  From: ${email.From || ""}`);
console.log(`  DefaultEmailOption: ${template.DefaultEmailOption || ""}`);
console.log(`  EmailSubject: ${template.EmailSubject || ""}`);
console.log(`  EmailMessage contains {####}: ${message.includes("{####}")}`);
console.log(`  EmailMessage UTF-8 bytes: ${Buffer.byteLength(message, "utf8")}`);
NODE

if [[ "${MODE}" == "check" ]]; then
  echo
  echo "Check only. Cognito was not modified."
  exit 0
fi

verify_logo

echo
echo "Building update request from the current pool..."
node <<'NODE'
const fs = require("fs");

const described = JSON.parse(fs.readFileSync(process.env.AZENTZ_DESCRIBE_BEFORE, "utf8"));
const pool = described.UserPool;
if (!pool || typeof pool !== "object") {
  console.error("ERROR: describe-user-pool did not return UserPool.");
  process.exit(1);
}

const html = fs.readFileSync(process.env.AZENTZ_HTML_FILE, "utf8");
const subject = process.env.AZENTZ_EMAIL_SUBJECT;
const verification = JSON.parse(fs.readFileSync(process.env.AZENTZ_VERIFICATION_JSON, "utf8"));
const emailConfiguration = JSON.parse(fs.readFileSync(process.env.AZENTZ_EMAIL_JSON, "utf8"));

const preserve = [
  "Policies",
  "DeletionProtection",
  "LambdaConfig",
  "AutoVerifiedAttributes",
  "SmsVerificationMessage",
  "EmailVerificationMessage",
  "EmailVerificationSubject",
  "VerificationMessageTemplate",
  "SmsAuthenticationMessage",
  "UserAttributeUpdateSettings",
  "MfaConfiguration",
  "DeviceConfiguration",
  "EmailConfiguration",
  "SmsConfiguration",
  "UserPoolTags",
  "AdminCreateUserConfig",
  "UserPoolAddOns",
  "AccountRecoverySetting",
  "PoolName",
  "UserPoolTier",
  "KeyConfiguration",
  "IssuerConfiguration"
];

function emptyObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) && Object.keys(value).length === 0;
}

const update = {
  UserPoolId: process.env.AZENTZ_USER_POOL_ID
};

for (const key of preserve) {
  const value = pool[key];
  if (value === undefined || value === null) continue;
  if (emptyObject(value)) continue;
  update[key] = value;
}

const attrs = Array.isArray(pool.AutoVerifiedAttributes) ? pool.AutoVerifiedAttributes.slice() : [];
if (!attrs.includes("email")) attrs.push("email");
update.AutoVerifiedAttributes = attrs;

const template = { ...(pool.VerificationMessageTemplate || {}) };
delete template.EmailMessageByLink;
delete template.EmailSubjectByLink;
template.DefaultEmailOption = verification.DefaultEmailOption;
template.EmailSubject = verification.EmailSubject;
template.EmailMessage = verification.EmailMessage;
update.VerificationMessageTemplate = template;

update.EmailVerificationSubject = subject;
update.EmailVerificationMessage = html;

const email = { ...(pool.EmailConfiguration || {}) };
email.EmailSendingAccount = emailConfiguration.EmailSendingAccount;
email.SourceArn = emailConfiguration.SourceArn;
email.From = emailConfiguration.From;
for (const key of Object.keys(email)) {
  if (email[key] === "" || email[key] === null || email[key] === undefined) {
    delete email[key];
  }
}
update.EmailConfiguration = email;

if (update.PoolName === undefined && pool.Name) {
  update.PoolName = pool.Name;
}

const admin = update.AdminCreateUserConfig;
const temporaryDays = pool.Policies && pool.Policies.PasswordPolicy
  ? pool.Policies.PasswordPolicy.TemporaryPasswordValidityDays
  : undefined;
if (admin && temporaryDays !== undefined && temporaryDays !== null) {
  delete admin.UnusedAccountValidityDays;
}

fs.writeFileSync(process.env.AZENTZ_UPDATE_JSON, JSON.stringify(update, null, 2));
console.log("  Preserved user pool fields:");
for (const key of Object.keys(update)) {
  if (key === "UserPoolId") continue;
  console.log(`    ${key}`);
}
console.log("  AutoVerifiedAttributes will include email");
console.log("  EmailMessageByLink will not be set");
NODE

echo
echo "Applying Cognito configuration..."
aws_az cognito-idp update-user-pool \
  --cli-input-json "file://${UPDATE_JSON}" \
  --output json

echo
echo "========================================"
echo " Verifying configuration"
echo "========================================"
echo

aws_az cognito-idp describe-user-pool \
  --user-pool-id "${USER_POOL_ID}" \
  --output json > "${DESCRIBE_AFTER}"

node <<'NODE'
const fs = require("fs");
const pool = JSON.parse(fs.readFileSync(process.env.AZENTZ_DESCRIBE_AFTER, "utf8")).UserPool || {};
const expectedHtml = fs.readFileSync(process.env.AZENTZ_HTML_FILE, "utf8");
const email = pool.EmailConfiguration || {};
const template = pool.VerificationMessageTemplate || {};
const attrs = pool.AutoVerifiedAttributes || [];
const failures = [];

if (!attrs.includes("email")) {
  failures.push("AutoVerifiedAttributes does not contain email");
}
if (email.EmailSendingAccount !== "DEVELOPER") {
  failures.push(`EmailSendingAccount is ${JSON.stringify(email.EmailSendingAccount)}`);
}
if (email.SourceArn !== process.env.AZENTZ_SES_SOURCE_ARN) {
  failures.push(`SourceArn is ${JSON.stringify(email.SourceArn || "")}`);
}
if (email.From !== process.env.AZENTZ_EMAIL_FROM) {
  failures.push(`From is ${JSON.stringify(email.From || "")}`);
}
if (template.DefaultEmailOption !== "CONFIRM_WITH_CODE") {
  failures.push(`DefaultEmailOption is ${JSON.stringify(template.DefaultEmailOption || "")}`);
}
if (template.EmailSubject !== process.env.AZENTZ_EMAIL_SUBJECT) {
  failures.push(`EmailSubject is ${JSON.stringify(template.EmailSubject || "")}`);
}
if (!String(template.EmailMessage || "").includes("{####}")) {
  failures.push("EmailMessage does not contain {####}");
}
if (template.EmailMessage !== expectedHtml) {
  failures.push("EmailMessage does not match verification.html");
}
if (template.EmailMessageByLink) {
  failures.push("EmailMessageByLink is set");
}

console.log(`AutoVerifiedAttributes: ${JSON.stringify(attrs)}`);
console.log(`EmailSendingAccount: ${email.EmailSendingAccount || ""}`);
console.log(`SourceArn: ${email.SourceArn || ""}`);
console.log(`From: ${email.From || ""}`);
console.log(`DefaultEmailOption: ${template.DefaultEmailOption || ""}`);
console.log(`EmailSubject: ${template.EmailSubject || ""}`);
console.log(`EmailMessage contains {####}: ${String(template.EmailMessage || "").includes("{####}")}`);
console.log(`EmailMessage matches template: ${template.EmailMessage === expectedHtml}`);

if (failures.length > 0) {
  console.error("");
  console.error("ERROR: Cognito verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
NODE

echo
echo "========================================"
echo " Done"
echo "========================================"
