#!/usr/bin/env bash
set -euo pipefail

repo="repos/${GH_REPO:?}"
sha="${GITHUB_SHA:?}"
tag="build-$sha"
ref="refs/tags/$tag"
assets=(VCSExplorer-arm64.zip SHA256SUMS build-info.txt)

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "Invalid commit SHA"
sha256sum --check --strict SHA256SUMS
grep -Fxq "Commit: $sha" build-info.txt

tag_commit() {
    gh api "$repo/git/matching-refs/tags/$tag" |
        jq -r --arg ref "$ref" '.[] | select(.ref == $ref) |
            if .object.type == "commit" then .object.sha else error("Tag is not a lightweight commit tag") end'
}

# A draft reserves its tag name even when it is absent from the public Releases list.
release=$(gh api "$repo/releases" --paginate --slurp |
    jq -c --arg tag "$tag" 'flatten | map(select(.tag_name == $tag)) |
        if length > 1 then error("Multiple releases for tag") else first // null end')
current_tag=$(tag_commit)
if [[ -z "$current_tag" && "$release" == null ]]; then
    gh api "$repo/git/refs" -f ref="$ref" -f sha="$sha" --silent
fi
[[ "$(tag_commit)" == "$sha" ]] || fail "Tag $tag does not point to $sha"

if [[ "$release" == null ]]; then
    release=$(gh api "$repo/releases" -f tag_name="$tag" -f target_commitish="$sha" \
        -f name="SwiftVCS preview ${sha:0:12}" -F draft=true -F prerelease=true -f make_latest=false \
        -f body="$(cat build-info.txt)"$'\n\nGitHub provides source ZIP and tar.gz archives for this tag.')
fi
id=$(jq -er '.id' <<< "$release")
jq -e '.prerelease' <<< "$release" > /dev/null || fail "$tag is not a preview release"

if [[ "$(jq -r '.draft' <<< "$release")" == true ]]; then
    upload_url=$(jq -er '.upload_url | split("{")[0]' <<< "$release")
    [[ "$upload_url" == "https://uploads.github.com/$repo/releases/$id/assets" ]] ||
        fail "Unexpected GitHub upload endpoint"
    for asset in "${assets[@]}"; do
        existing=$(gh api "$repo/releases/$id/assets" |
            jq -c --arg name "$asset" 'map(select(.name == $name)) | first // null')
        expected="sha256:$(sha256sum "$asset" | awk '{print $1}')"
        if [[ "$existing" != null ]]; then
            if jq -e '.state == "starter" and .size == 0' <<< "$existing" > /dev/null; then
                printf 'Removing incomplete upload of %s from draft\n' "$asset"
                gh api --method DELETE "$repo/releases/assets/$(jq -er '.id' <<< "$existing")" --silent
            else
                jq -e --arg digest "$expected" '.state == "uploaded" and .digest == $digest' \
                    <<< "$existing" > /dev/null || fail "Draft attachment $asset differs from the build"
                continue
            fi
        fi
        curl --fail-with-body --silent --show-error \
            --header "Authorization: Bearer ${GH_TOKEN:?}" --header "Content-Type: application/octet-stream" \
            --data-binary "@$asset" "$upload_url?name=$asset" |
            jq -e --arg digest "$expected" '.state == "uploaded" and .digest == $digest' > /dev/null
    done
    [[ "$(tag_commit)" == "$sha" ]] || fail "Tag changed during upload"
    gh api --method PATCH "$repo/releases/$id" -F draft=false -f make_latest=false --silent
fi

# Verify what readers can download, including when a previous run published this commit.
verify_dir=$(mktemp -d)
trap 'rm -rf "$verify_dir"' EXIT
asset_index=$(gh api "$repo/releases/$id/assets")
for asset in "${assets[@]}"; do
    asset_id=$(jq -er --arg name "$asset" '.[] | select(.name == $name and .state == "uploaded") | .id' <<< "$asset_index")
    gh api "$repo/releases/assets/$asset_id" -H 'Accept: application/octet-stream' > "$verify_dir/$asset"
done
(
    cd "$verify_dir"
    sha256sum --check --strict SHA256SUMS
    grep -Fxq "Commit: $sha" build-info.txt
)
[[ "$(tag_commit)" == "$sha" ]] || fail "Published tag no longer points to $sha"
# Exercise both GitHub-generated archives for the verified tag.
gh api "$repo/zipball/$tag" > "$verify_dir/source.zip"
gh api "$repo/tarball/$tag" > "$verify_dir/source.tar.gz"
unzip -tq "$verify_dir/source.zip"
tar -tzf "$verify_dir/source.tar.gz" > /dev/null
gh api "$repo/releases/$id" --jq '.html_url'
