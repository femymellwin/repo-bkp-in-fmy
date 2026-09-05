#!/usr/bin/env bash

# Build a people, access, ownership, and last-commit inventory for one
# GitHub Enterprise Server organization.
#
# Required:
#   export GHES_TOKEN='...'
#   export GHES_ORG='DOF-MBO'          # or pass the org as argument 1
#
# Optional:
#   export GHES_URL='https://github.int.inceptionai.ai'
#   export GHES_API_URL="$GHES_URL/api/v3"
#   export GHES_API_VERSION=''         # normally leave empty for GHES
#   export NO_SSL_VERIFY='false'
#   export INCLUDE_CODEOWNERS='true'
#   export INCLUDE_TEAM_MEMBERS='true'
#   export OUTPUT_DIR='/path/to/output'
#
# Usage:
#   ./ghes-org-people-inventory.sh
#   ./ghes-org-people-inventory.sh DOF-MBO
#
# Dependencies: curl, jq, awk, sed, grep, sort, base64
# Compatible with Bash 3.2 (macOS default).

set -u
set -o pipefail
umask 077

GHES_URL="${GHES_URL:-https://github.int.inceptionai.ai}"
GHES_API_URL="${GHES_API_URL:-${GHES_URL%/}/api/v3}"
GHES_ORG="${GHES_ORG:-${1:-}}"
GHES_TOKEN="${GHES_TOKEN:-}"
GHES_API_VERSION="${GHES_API_VERSION:-}"
NO_SSL_VERIFY="${NO_SSL_VERIFY:-false}"
INCLUDE_CODEOWNERS="${INCLUDE_CODEOWNERS:-true}"
INCLUDE_TEAM_MEMBERS="${INCLUDE_TEAM_MEMBERS:-true}"
RUN_ID="$(date -u '+%Y%m%d-%H%M%S')"
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/ghes-inventory-${GHES_ORG:-unknown}-${RUN_ID}}"

WORK_ROOT=""
ERROR_LOG=""
USER_CACHE_DIR=""
TEAM_MEMBER_CACHE_DIR=""
MEMBER_LOGINS=""
OWNER_LOGINS=""
OUTSIDE_LOGINS=""

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >&2
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*" >&2
  exit 1
}

is_true() {
  case "${1:-}" in
    true|TRUE|True|yes|YES|Yes|1) return 0 ;;
    *) return 1 ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

safe_file_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

csv_row() {
  jq -rn --args '$ARGS.positional | @csv' -- "$@"
}

cleanup() {
  if [ -n "${WORK_ROOT:-}" ] && [ -d "$WORK_ROOT" ]; then
    rm -rf "$WORK_ROOT"
  fi
}
trap cleanup EXIT

api_request() {
  # api_request METHOD API_PATH OUTPUT_FILE
  # Prints the HTTP status code. API_PATH must begin with '/'.
  method="$1"
  api_path="$2"
  output_file="$3"

  curl_args=(
    -sS
    -L
    -o "$output_file"
    -w '%{http_code}'
    -H 'Accept: application/vnd.github+json'
    -H "Authorization: Bearer $GHES_TOKEN"
    -H 'User-Agent: ghes-org-people-inventory'
  )

  if [ -n "$GHES_API_VERSION" ]; then
    curl_args+=( -H "X-GitHub-Api-Version: $GHES_API_VERSION" )
  fi
  if is_true "$NO_SSL_VERIFY"; then
    curl_args+=( -k )
  fi
  if [ "$method" != "GET" ]; then
    curl_args+=( -X "$method" )
  fi

  code="$(curl "${curl_args[@]}" "${GHES_API_URL%/}${api_path}" 2>>"$ERROR_LOG")"
  status=$?
  if [ "$status" -ne 0 ]; then
    printf 'curl failure (%s) for %s %s\n' "$status" "$method" "$api_path" >> "$ERROR_LOG"
    printf '000'
    return "$status"
  fi
  printf '%s' "$code"
  return 0
}

record_api_error() {
  label="$1"
  code="$2"
  path="$3"
  body_file="$4"
  {
    printf '\n[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$label"
    printf 'HTTP: %s\nPath: %s\n' "$code" "$path"
    cat "$body_file" 2>/dev/null || true
    printf '\n'
  } >> "$ERROR_LOG"
}

paginate_array() {
  # paginate_array API_PATH OUTPUT_JSONL LABEL
  # API_PATH may already contain query parameters.
  base_path="$1"
  output_jsonl="$2"
  label="$3"
  : > "$output_jsonl"

  page=1
  while :; do
    case "$base_path" in
      *\?*) path="${base_path}&per_page=100&page=${page}" ;;
      *) path="${base_path}?per_page=100&page=${page}" ;;
    esac
    body="$WORK_ROOT/page-$(safe_file_name "$label")-${page}.json"
    code="$(api_request GET "$path" "$body")"
    status=$?
    if [ "$status" -ne 0 ] || [ "$code" != "200" ]; then
      record_api_error "Could not paginate $label" "$code" "$path" "$body"
      return 1
    fi
    if ! jq -e 'type == "array"' "$body" >/dev/null 2>&1; then
      record_api_error "Non-array response while paginating $label" "$code" "$path" "$body"
      return 1
    fi

    jq -c '.[]' "$body" >> "$output_jsonl"
    count="$(jq 'length' "$body")"
    if [ "$count" -lt 100 ]; then
      break
    fi
    page=$((page + 1))
  done
  return 0
}

get_user_profile_file() {
  login="$1"
  if [ -z "$login" ] || [ "$login" = "null" ]; then
    printf '%s' "$WORK_ROOT/empty-user.json"
    return 0
  fi

  cache="$USER_CACHE_DIR/$(safe_file_name "$login").json"
  if [ -f "$cache" ]; then
    printf '%s' "$cache"
    return 0
  fi

  encoded_login="$(urlencode "$login")"
  body="$cache.tmp"
  path="/users/$encoded_login"
  code="$(api_request GET "$path" "$body")"
  status=$?
  if [ "$status" -eq 0 ] && [ "$code" = "200" ]; then
    mv "$body" "$cache"
  else
    record_api_error "Could not retrieve user profile for $login" "$code" "$path" "$body"
    printf '{}\n' > "$cache"
    rm -f "$body"
  fi
  printf '%s' "$cache"
}

login_in_file() {
  login="$1"
  file="$2"
  [ -s "$file" ] && grep -Fqx "$login" "$file"
}

classify_org_relationship() {
  login="$1"
  if login_in_file "$login" "$OWNER_LOGINS"; then
    printf 'organization_owner'
  elif login_in_file "$login" "$MEMBER_LOGINS"; then
    printf 'organization_member'
  elif login_in_file "$login" "$OUTSIDE_LOGINS"; then
    printf 'outside_collaborator'
  else
    printf 'other_or_inherited'
  fi
}

decode_base64_stream() {
  if printf '' | base64 --decode >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

write_people_row() {
  relationship="$1"
  role="$2"
  login="$3"

  profile="$(get_user_profile_file "$login")"
  full_name="$(jq -r '.name // ""' "$profile")"
  public_email="$(jq -r '.email // ""' "$profile")"
  company="$(jq -r '.company // ""' "$profile")"
  location="$(jq -r '.location // ""' "$profile")"
  profile_url="$(jq -r '.html_url // ""' "$profile")"
  site_admin="$(jq -r '.site_admin // false' "$profile")"
  account_type="$(jq -r '.type // ""' "$profile")"

  csv_row "$GHES_ORG" "$relationship" "$role" "$login" "$full_name" "$public_email" \
    "$company" "$location" "$account_type" "$site_admin" "$profile_url" >> "$OUTPUT_DIR/organization_people.csv"
}

fetch_team_members_jsonl() {
  team_slug="$1"
  cache="$TEAM_MEMBER_CACHE_DIR/$(safe_file_name "$team_slug").jsonl"
  if [ -f "$cache" ]; then
    printf '%s' "$cache"
    return 0
  fi

  encoded_org="$(urlencode "$GHES_ORG")"
  encoded_team="$(urlencode "$team_slug")"
  if paginate_array "/orgs/$encoded_org/teams/$encoded_team/members?role=all" "$cache" "team-members-$team_slug"; then
    printf '%s' "$cache"
    return 0
  fi

  : > "$cache"
  printf '%s' "$cache"
  return 1
}

write_team_members_for_team() {
  team_slug="$1"
  team_name="$2"
  team_privacy="$3"

  members_jsonl="$(fetch_team_members_jsonl "$team_slug")"
  while IFS= read -r member_json; do
    [ -z "$member_json" ] && continue
    login="$(printf '%s' "$member_json" | jq -r '.login // ""')"
    [ -z "$login" ] && continue
    profile="$(get_user_profile_file "$login")"
    full_name="$(jq -r '.name // ""' "$profile")"
    public_email="$(jq -r '.email // ""' "$profile")"
    profile_url="$(jq -r '.html_url // ""' "$profile")"
    csv_row "$GHES_ORG" "$team_slug" "$team_name" "$team_privacy" "$login" "$full_name" "$public_email" "$profile_url" \
      >> "$OUTPUT_DIR/team_members.csv"
  done < "$members_jsonl"
}

collect_codeowners() {
  repository="$1"
  default_branch="$2"

  [ -z "$default_branch" ] && return 0
  is_true "$INCLUDE_CODEOWNERS" || return 0

  encoded_org="$(urlencode "$GHES_ORG")"
  encoded_repo="$(urlencode "$repository")"
  encoded_branch="$(urlencode "$default_branch")"

  codeowners_path=""
  content_json=""
  for candidate in '.github/CODEOWNERS' 'CODEOWNERS' 'docs/CODEOWNERS'; do
    body="$WORK_ROOT/codeowners-$(safe_file_name "$repository-$candidate").json"
    path="/repos/$encoded_org/$encoded_repo/contents/$candidate?ref=$encoded_branch"
    code="$(api_request GET "$path" "$body")"
    status=$?
    if [ "$status" -eq 0 ] && [ "$code" = "200" ]; then
      codeowners_path="$candidate"
      content_json="$body"
      break
    fi
    if [ "$code" != "404" ]; then
      record_api_error "Could not inspect CODEOWNERS candidate for $repository" "$code" "$path" "$body"
    fi
  done

  [ -z "$codeowners_path" ] && return 0

  decoded="$WORK_ROOT/codeowners-$(safe_file_name "$repository").txt"
  jq -r '.content // ""' "$content_json" | tr -d '\n' | decode_base64_stream > "$decoded" 2>>"$ERROR_LOG" || {
    warn "Could not decode CODEOWNERS for $repository"
    return 1
  }

  parsed="$WORK_ROOT/codeowners-$(safe_file_name "$repository").tsv"
  awk '
    {
      sub(/\r$/, "", $0)
      if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
      count=split($0, fields, /[[:space:]]+/)
      if (count < 2) next
      pattern=fields[1]
      for (i=2; i<=count; i++) {
        if (fields[i] != "") print pattern "\t" fields[i]
      }
    }
  ' "$decoded" > "$parsed"

  while IFS="$(printf '\t')" read -r pattern owner_token; do
    [ -z "$owner_token" ] && continue
    owner_type="unknown"
    principal=""
    full_name=""
    public_email=""

    case "$owner_token" in
      @*/*)
        owner_type="team"
        principal="${owner_token#@}"
        ;;
      @*)
        owner_type="user"
        principal="${owner_token#@}"
        profile="$(get_user_profile_file "$principal")"
        full_name="$(jq -r '.name // ""' "$profile")"
        public_email="$(jq -r '.email // ""' "$profile")"
        ;;
      *@*)
        owner_type="email"
        principal="$owner_token"
        public_email="$owner_token"
        ;;
      *)
        owner_type="unknown"
        principal="$owner_token"
        ;;
    esac

    csv_row "$repository" "$default_branch" "$codeowners_path" "$pattern" "$owner_token" "$owner_type" \
      "$principal" "$full_name" "$public_email" >> "$OUTPUT_DIR/repository_codeowners.csv"
  done < "$parsed"
}

collect_last_commit() {
  repository="$1"
  default_branch="$2"

  encoded_org="$(urlencode "$GHES_ORG")"
  encoded_repo="$(urlencode "$repository")"

  if [ -z "$default_branch" ]; then
    csv_row "$repository" "$default_branch" "" "" "No default branch or no commits" \
      "" "" "" "" "" "" \
      "" "" "" "" "" "" "" "" >> "$OUTPUT_DIR/repository_last_commit.csv"
    return 0
  fi

  encoded_branch="$(urlencode "$default_branch")"
  body="$WORK_ROOT/last-commit-$(safe_file_name "$repository").json"
  path="/repos/$encoded_org/$encoded_repo/commits?sha=$encoded_branch&per_page=1"
  code="$(api_request GET "$path" "$body")"
  status=$?

  if [ "$status" -ne 0 ] || { [ "$code" != "200" ] && [ "$code" != "409" ]; }; then
    record_api_error "Could not retrieve last commit for $repository" "$code" "$path" "$body"
    csv_row "$repository" "$default_branch" "" "" "API error: HTTP $code" \
      "" "" "" "" "" "" \
      "" "" "" "" "" "" "" "" >> "$OUTPUT_DIR/repository_last_commit.csv"
    return 1
  fi

  if [ "$code" = "409" ] || ! jq -e 'type == "array" and length > 0' "$body" >/dev/null 2>&1; then
    csv_row "$repository" "$default_branch" "" "" "Repository has no commits" \
      "" "" "" "" "" "" \
      "" "" "" "" "" "" "" "" >> "$OUTPUT_DIR/repository_last_commit.csv"
    return 0
  fi

  sha="$(jq -r '.[0].sha // ""' "$body")"
  commit_url="$(jq -r '.[0].html_url // ""' "$body")"
  message="$(jq -r '.[0].commit.message // ""' "$body")"

  author_login="$(jq -r '.[0].author.login // ""' "$body")"
  git_author_name="$(jq -r '.[0].commit.author.name // ""' "$body")"
  git_author_email="$(jq -r '.[0].commit.author.email // ""' "$body")"
  git_author_date="$(jq -r '.[0].commit.author.date // ""' "$body")"
  author_profile_name=""
  author_profile_email=""
  if [ -n "$author_login" ]; then
    author_profile="$(get_user_profile_file "$author_login")"
    author_profile_name="$(jq -r '.name // ""' "$author_profile")"
    author_profile_email="$(jq -r '.email // ""' "$author_profile")"
  fi

  committer_login="$(jq -r '.[0].committer.login // ""' "$body")"
  git_committer_name="$(jq -r '.[0].commit.committer.name // ""' "$body")"
  git_committer_email="$(jq -r '.[0].commit.committer.email // ""' "$body")"
  git_committer_date="$(jq -r '.[0].commit.committer.date // ""' "$body")"
  committer_profile_name=""
  committer_profile_email=""
  if [ -n "$committer_login" ]; then
    committer_profile="$(get_user_profile_file "$committer_login")"
    committer_profile_name="$(jq -r '.name // ""' "$committer_profile")"
    committer_profile_email="$(jq -r '.email // ""' "$committer_profile")"
  fi

  verified="$(jq -r '.[0].commit.verification.verified // false' "$body")"
  verification_reason="$(jq -r '.[0].commit.verification.reason // ""' "$body")"

  csv_row "$repository" "$default_branch" "$sha" "$commit_url" "$message" \
    "$author_login" "$author_profile_name" "$author_profile_email" "$git_author_name" "$git_author_email" "$git_author_date" \
    "$committer_login" "$committer_profile_name" "$committer_profile_email" "$git_committer_name" "$git_committer_email" "$git_committer_date" \
    "$verified" "$verification_reason" >> "$OUTPUT_DIR/repository_last_commit.csv"
}

collect_repo_collaborators() {
  repository="$1"

  encoded_org="$(urlencode "$GHES_ORG")"
  encoded_repo="$(urlencode "$repository")"
  collaborators="$WORK_ROOT/collaborators-$(safe_file_name "$repository").jsonl"

  if ! paginate_array "/repos/$encoded_org/$encoded_repo/collaborators?affiliation=all" "$collaborators" "repo-collaborators-$repository"; then
    warn "Could not list collaborators for $GHES_ORG/$repository. The token may lack repository administration/push access."
    return 1
  fi

  while IFS= read -r collaborator_json; do
    [ -z "$collaborator_json" ] && continue
    login="$(printf '%s' "$collaborator_json" | jq -r '.login // ""')"
    [ -z "$login" ] && continue
    profile="$(get_user_profile_file "$login")"
    full_name="$(jq -r '.name // ""' "$profile")"
    public_email="$(jq -r '.email // ""' "$profile")"
    profile_url="$(jq -r '.html_url // ""' "$profile")"
    relationship="$(classify_org_relationship "$login")"
    role_name="$(printf '%s' "$collaborator_json" | jq -r '.role_name // ""')"
    admin="$(printf '%s' "$collaborator_json" | jq -r '.permissions.admin // false')"
    maintain="$(printf '%s' "$collaborator_json" | jq -r '.permissions.maintain // false')"
    push="$(printf '%s' "$collaborator_json" | jq -r '.permissions.push // false')"
    triage="$(printf '%s' "$collaborator_json" | jq -r '.permissions.triage // false')"
    pull="$(printf '%s' "$collaborator_json" | jq -r '.permissions.pull // false')"

    csv_row "$repository" "$login" "$full_name" "$public_email" "$relationship" "$role_name" \
      "$admin" "$maintain" "$push" "$triage" "$pull" "$profile_url" >> "$OUTPUT_DIR/repository_access.csv"
  done < "$collaborators"
}

collect_repo_teams() {
  repository="$1"

  encoded_org="$(urlencode "$GHES_ORG")"
  encoded_repo="$(urlencode "$repository")"
  repo_teams="$WORK_ROOT/repo-teams-$(safe_file_name "$repository").jsonl"

  if ! paginate_array "/repos/$encoded_org/$encoded_repo/teams" "$repo_teams" "repo-teams-$repository"; then
    warn "Could not list repository teams for $GHES_ORG/$repository."
    return 1
  fi

  while IFS= read -r team_json; do
    [ -z "$team_json" ] && continue
    team_slug="$(printf '%s' "$team_json" | jq -r '.slug // ""')"
    team_name="$(printf '%s' "$team_json" | jq -r '.name // ""')"
    permission="$(printf '%s' "$team_json" | jq -r '.permission // ""')"
    privacy="$(printf '%s' "$team_json" | jq -r '.privacy // ""')"
    parent_slug="$(printf '%s' "$team_json" | jq -r '.parent.slug // ""')"
    team_url="$(printf '%s' "$team_json" | jq -r '.html_url // ""')"

    csv_row "$repository" "$team_slug" "$team_name" "$permission" "$privacy" "$parent_slug" "$team_url" \
      >> "$OUTPUT_DIR/repository_teams.csv"

    if is_true "$INCLUDE_TEAM_MEMBERS" && [ -n "$team_slug" ]; then
      members_jsonl="$(fetch_team_members_jsonl "$team_slug")"
      while IFS= read -r member_json; do
        [ -z "$member_json" ] && continue
        login="$(printf '%s' "$member_json" | jq -r '.login // ""')"
        [ -z "$login" ] && continue
        profile="$(get_user_profile_file "$login")"
        full_name="$(jq -r '.name // ""' "$profile")"
        public_email="$(jq -r '.email // ""' "$profile")"
        relationship="$(classify_org_relationship "$login")"
        csv_row "$repository" "$team_slug" "$team_name" "$permission" "$login" "$full_name" "$public_email" "$relationship" \
          >> "$OUTPUT_DIR/repository_team_members.csv"
      done < "$members_jsonl"
    fi
  done < "$repo_teams"
}

write_readme() {
  cat > "$OUTPUT_DIR/README.txt" <<EOF
GHES organization people and repository ownership inventory
===========================================================

Organization: $GHES_ORG
GHES URL:     $GHES_URL
API URL:      $GHES_API_URL
Created:      $(date -u '+%Y-%m-%d %H:%M:%S UTC')

Files
-----
organization_people.csv
  Active organization owners/members and outside collaborators, enriched with
  profile name and profile email when the account exposes them.

pending_invitations.csv
  Pending organization invitations. The invitation email is included when the
  API returns it.

organization_teams.csv
  Organization team inventory.

team_members.csv
  Organization team memberships.

repositories.csv
  Repository metadata and default branch.

repository_access.csv
  Effective repository collaborators and permission flags. GitHub's collaborator
  endpoint includes access through direct grants, teams, organization defaults,
  outside collaboration, and organization ownership. It does not identify which
  one of those mechanisms produced each effective permission.

repository_teams.csv
  Teams explicitly assigned to each repository and their repository permission.

repository_team_members.csv
  Flattened repository -> team -> person access mapping.

repository_codeowners.csv
  CODEOWNERS patterns and owner principals from the default branch. The search
  order is .github/CODEOWNERS, CODEOWNERS, then docs/CODEOWNERS.

repository_last_commit.csv
  Last commit on each default branch. It contains both Git commit identity
  (commit author/committer name and email embedded in the commit) and the linked
  GHES account identity when GitHub associates the commit with an account.

errors.log
  API failures and permission-related gaps.

Email limitation
----------------
The profile email returned by GET /users/{login} is normally only the user's
visible profile email. A token belonging to an organization owner does not grant
access to every user's private account email. Commit email fields come from Git
commit metadata and can be a private-address alias, a noreply address, stale, or
unverified. Pending invitation emails are a separate source and only apply to
pending invitations.

Recommended classic PAT access
------------------------------
- repo        Read all private repositories and repository access information.
- read:org    Read organization membership and teams.
- The token holder should be an organization owner for the most complete view.
- Some GHES configurations/endpoints may require site-admin privileges.
EOF
}

main() {
  [ -n "$GHES_ORG" ] || die "Set GHES_ORG or pass the organization name as argument 1."
  [ -n "$GHES_TOKEN" ] || die "GHES_TOKEN is empty. Export the source GHES token before running."

  require_command curl
  require_command jq
  require_command awk
  require_command sed
  require_command grep
  require_command sort
  require_command base64

  mkdir -p "$OUTPUT_DIR" || die "Could not create output directory: $OUTPUT_DIR"
  WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ghes-people-inventory.XXXXXX")" || die "Could not create temporary directory."
  ERROR_LOG="$OUTPUT_DIR/errors.log"
  USER_CACHE_DIR="$WORK_ROOT/user-cache"
  TEAM_MEMBER_CACHE_DIR="$WORK_ROOT/team-member-cache"
  MEMBER_LOGINS="$WORK_ROOT/member-logins.txt"
  OWNER_LOGINS="$WORK_ROOT/owner-logins.txt"
  OUTSIDE_LOGINS="$WORK_ROOT/outside-logins.txt"
  mkdir -p "$USER_CACHE_DIR" "$TEAM_MEMBER_CACHE_DIR"
  : > "$ERROR_LOG"
  : > "$MEMBER_LOGINS"
  : > "$OWNER_LOGINS"
  : > "$OUTSIDE_LOGINS"
  printf '{}\n' > "$WORK_ROOT/empty-user.json"

  # CSV headers.
  csv_row organization relationship membership_role login full_name profile_public_email company location account_type site_admin profile_url > "$OUTPUT_DIR/organization_people.csv"
  csv_row organization invitation_id login invitation_email role invitation_source inviter_login created_at > "$OUTPUT_DIR/pending_invitations.csv"
  csv_row organization team_slug team_name privacy parent_team_slug description members_count repos_count team_url > "$OUTPUT_DIR/organization_teams.csv"
  csv_row organization team_slug team_name team_privacy login full_name profile_public_email profile_url > "$OUTPUT_DIR/team_members.csv"
  csv_row repository visibility private archived fork default_branch has_issues has_wiki size_kb repo_url > "$OUTPUT_DIR/repositories.csv"
  csv_row repository login full_name profile_public_email org_relationship role_name admin maintain push triage pull profile_url > "$OUTPUT_DIR/repository_access.csv"
  csv_row repository team_slug team_name repository_permission team_privacy parent_team_slug team_url > "$OUTPUT_DIR/repository_teams.csv"
  csv_row repository team_slug team_name repository_permission login full_name profile_public_email org_relationship > "$OUTPUT_DIR/repository_team_members.csv"
  csv_row repository default_branch codeowners_path pattern owner_token owner_type principal full_name profile_public_email > "$OUTPUT_DIR/repository_codeowners.csv"
  csv_row repository default_branch sha commit_url message author_login author_profile_name author_profile_public_email git_author_name git_author_email git_author_date committer_login committer_profile_name committer_profile_public_email git_committer_name git_committer_email git_committer_date verified verification_reason > "$OUTPUT_DIR/repository_last_commit.csv"

  encoded_org="$(urlencode "$GHES_ORG")"

  log "Validating GHES token against $GHES_API_URL"
  auth_body="$WORK_ROOT/authenticated-user.json"
  auth_code="$(api_request GET '/user' "$auth_body")"
  [ "$auth_code" = "200" ] || die "Authentication failed with HTTP $auth_code. See $ERROR_LOG"
  auth_login="$(jq -r '.login // "unknown"' "$auth_body")"
  log "Authenticated as: $auth_login"

  org_body="$WORK_ROOT/organization.json"
  org_path="/orgs/$encoded_org"
  org_code="$(api_request GET "$org_path" "$org_body")"
  [ "$org_code" = "200" ] || die "Cannot read organization $GHES_ORG (HTTP $org_code). See $ERROR_LOG"

  log "Collecting organization members and owners"
  members_jsonl="$WORK_ROOT/members.jsonl"
  owners_jsonl="$WORK_ROOT/owners.jsonl"
  outside_jsonl="$WORK_ROOT/outside.jsonl"
  invitations_jsonl="$WORK_ROOT/invitations.jsonl"

  paginate_array "/orgs/$encoded_org/members?filter=all&role=all" "$members_jsonl" "organization-members" || die "Could not list organization members. See $ERROR_LOG"
  paginate_array "/orgs/$encoded_org/members?filter=all&role=admin" "$owners_jsonl" "organization-owners" || : > "$owners_jsonl"
  paginate_array "/orgs/$encoded_org/outside_collaborators?filter=all" "$outside_jsonl" "outside-collaborators" || : > "$outside_jsonl"
  paginate_array "/orgs/$encoded_org/invitations" "$invitations_jsonl" "pending-invitations" || : > "$invitations_jsonl"

  jq -r '.login // empty' "$members_jsonl" | sort -u > "$MEMBER_LOGINS"
  jq -r '.login // empty' "$owners_jsonl" | sort -u > "$OWNER_LOGINS"
  jq -r '.login // empty' "$outside_jsonl" | sort -u > "$OUTSIDE_LOGINS"

  while IFS= read -r login; do
    [ -z "$login" ] && continue
    if login_in_file "$login" "$OWNER_LOGINS"; then
      write_people_row "member" "owner" "$login"
    else
      write_people_row "member" "member" "$login"
    fi
  done < "$MEMBER_LOGINS"

  while IFS= read -r login; do
    [ -z "$login" ] && continue
    write_people_row "outside_collaborator" "outside_collaborator" "$login"
  done < "$OUTSIDE_LOGINS"

  while IFS= read -r invitation_json; do
    [ -z "$invitation_json" ] && continue
    invitation_id="$(printf '%s' "$invitation_json" | jq -r '.id // ""')"
    login="$(printf '%s' "$invitation_json" | jq -r '.login // ""')"
    invitation_email="$(printf '%s' "$invitation_json" | jq -r '.email // ""')"
    role="$(printf '%s' "$invitation_json" | jq -r '.role // ""')"
    invitation_source="$(printf '%s' "$invitation_json" | jq -r '.invitation_source // ""')"
    inviter_login="$(printf '%s' "$invitation_json" | jq -r '.inviter.login // ""')"
    created_at="$(printf '%s' "$invitation_json" | jq -r '.created_at // ""')"
    csv_row "$GHES_ORG" "$invitation_id" "$login" "$invitation_email" "$role" "$invitation_source" "$inviter_login" "$created_at" \
      >> "$OUTPUT_DIR/pending_invitations.csv"
  done < "$invitations_jsonl"

  log "Collecting organization teams"
  teams_jsonl="$WORK_ROOT/teams.jsonl"
  if paginate_array "/orgs/$encoded_org/teams" "$teams_jsonl" "organization-teams"; then
    while IFS= read -r team_json; do
      [ -z "$team_json" ] && continue
      team_slug="$(printf '%s' "$team_json" | jq -r '.slug // ""')"
      team_name="$(printf '%s' "$team_json" | jq -r '.name // ""')"
      privacy="$(printf '%s' "$team_json" | jq -r '.privacy // ""')"
      parent_slug="$(printf '%s' "$team_json" | jq -r '.parent.slug // ""')"
      description="$(printf '%s' "$team_json" | jq -r '.description // ""')"
      members_count="$(printf '%s' "$team_json" | jq -r '.members_count // ""')"
      repos_count="$(printf '%s' "$team_json" | jq -r '.repos_count // ""')"
      team_url="$(printf '%s' "$team_json" | jq -r '.html_url // ""')"
      csv_row "$GHES_ORG" "$team_slug" "$team_name" "$privacy" "$parent_slug" "$description" "$members_count" "$repos_count" "$team_url" \
        >> "$OUTPUT_DIR/organization_teams.csv"
      if is_true "$INCLUDE_TEAM_MEMBERS" && [ -n "$team_slug" ]; then
        write_team_members_for_team "$team_slug" "$team_name" "$privacy"
      fi
    done < "$teams_jsonl"
  else
    warn "Organization team inventory is incomplete."
  fi

  log "Collecting repositories"
  repositories_jsonl="$WORK_ROOT/repositories.jsonl"
  paginate_array "/orgs/$encoded_org/repos?type=all&sort=full_name&direction=asc" "$repositories_jsonl" "organization-repositories" || die "Could not list repositories. See $ERROR_LOG"
  repository_count="$(wc -l < "$repositories_jsonl" | tr -d ' ')"
  log "Repositories found: $repository_count"

  index=0
  while IFS= read -r repo_json; do
    [ -z "$repo_json" ] && continue
    index=$((index + 1))
    repository="$(printf '%s' "$repo_json" | jq -r '.name // ""')"
    [ -z "$repository" ] && continue
    visibility="$(printf '%s' "$repo_json" | jq -r '.visibility // (if .private then "private" else "public" end)')"
    private="$(printf '%s' "$repo_json" | jq -r '.private // false')"
    archived="$(printf '%s' "$repo_json" | jq -r '.archived // false')"
    fork="$(printf '%s' "$repo_json" | jq -r '.fork // false')"
    default_branch="$(printf '%s' "$repo_json" | jq -r '.default_branch // ""')"
    has_issues="$(printf '%s' "$repo_json" | jq -r '.has_issues // false')"
    has_wiki="$(printf '%s' "$repo_json" | jq -r '.has_wiki // false')"
    size_kb="$(printf '%s' "$repo_json" | jq -r '.size // 0')"
    repo_url="$(printf '%s' "$repo_json" | jq -r '.html_url // ""')"

    log "[$index/$repository_count] $GHES_ORG/$repository"
    csv_row "$repository" "$visibility" "$private" "$archived" "$fork" "$default_branch" "$has_issues" "$has_wiki" "$size_kb" "$repo_url" \
      >> "$OUTPUT_DIR/repositories.csv"

    collect_repo_collaborators "$repository" || true
    collect_repo_teams "$repository" || true
    collect_codeowners "$repository" "$default_branch" || true
    collect_last_commit "$repository" "$default_branch" || true
  done < "$repositories_jsonl"

  write_readme

  member_count="$(tail -n +2 "$OUTPUT_DIR/organization_people.csv" | wc -l | tr -d ' ')"
  access_count="$(tail -n +2 "$OUTPUT_DIR/repository_access.csv" | wc -l | tr -d ' ')"
  commit_count="$(tail -n +2 "$OUTPUT_DIR/repository_last_commit.csv" | wc -l | tr -d ' ')"
  error_bytes="$(wc -c < "$ERROR_LOG" | tr -d ' ')"

  log "Inventory complete"
  log "People rows: $member_count"
  log "Repository access rows: $access_count"
  log "Last-commit rows: $commit_count"
  if [ "$error_bytes" -gt 0 ]; then
    warn "Some API calls were incomplete. Review: $ERROR_LOG"
  fi
  printf '%s\n' "$OUTPUT_DIR"
}

main "$@"
