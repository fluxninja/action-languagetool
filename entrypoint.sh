#!/bin/bash
set -eo pipefail

echo "API ENDPOINT: ${INPUT_API_ENDPOINT}" >&2

if [ -n "${GITHUB_WORKSPACE}" ]; then
	cd "${GITHUB_WORKSPACE}" || exit
fi

git config --global --add safe.directory "$GITHUB_WORKSPACE"

# https://languagetool.org/http-api/swagger-ui/#!/default/post_check
DATA="language=${INPUT_LANGUAGE}"
if [ -n "${INPUT_ENABLED_RULES}" ]; then
	DATA="$DATA&enabledRules=${INPUT_ENABLED_RULES}"
fi
if [ -n "${INPUT_DISABLED_RULES}" ]; then
	DATA="$DATA&disabledRules=${INPUT_DISABLED_RULES}"
fi
if [ -n "${INPUT_ENABLED_CATEGORIES}" ]; then
	DATA="$DATA&enabledCategories=${INPUT_ENABLED_CATEGORIES}"
fi
if [ -n "${INPUT_DISABLED_CATEGORIES}" ]; then
	DATA="$DATA&disabledCategories=${INPUT_DISABLED_CATEGORIES}"
fi
if [ -n "${INPUT_ENABLED_ONLY}" ]; then
	DATA="$DATA&enabledOnly=${INPUT_ENABLED_ONLY}"
fi
if [ -n "${INPUT_USERNAME}" ]; then
	DATA="$DATA&username=${INPUT_USERNAME}"
fi
if [ -n "${INPUT_API_KEY}" ]; then
	DATA="$DATA&apiKey=${INPUT_API_KEY}"
fi

# Disable glob to handle glob patterns with ghglob command instead of with shell.
set -o noglob

if [ "${INPUT_FILTER_FILES}" = "changed" ]; then
	PR_NUMBER=$(echo "${GITHUB_REF}" | awk -F / '{print $3}')
	PAGE=1
	FILES=""
	while :; do
		RESPONSE="$(curl --silent -H "Authorization: token ${INPUT_GITHUB_TOKEN}" \
			"https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/files?per_page=100&page=${PAGE}")"
		PAGE_FILES="$(echo "${RESPONSE}" | jq -r '.[] | select(.status != "deleted") | .filename' | ghglob "${INPUT_PATTERNS}")"
		if [ -z "${PAGE_FILES}" ]; then
			break
		fi
		FILES="${FILES}${PAGE_FILES}"
		PAGE=$((PAGE + 1))
	done
else
	FILES="$(git ls-files | ghglob "${INPUT_PATTERNS}")"
fi

# echo list of files to check
echo "Files to check:"
echo "${FILES}"

set +o noglob

urlencode() {
	local input="$1"
	local output=""
	while IFS= read -r -n1 char; do
		if [[ "${char}" =~ [a-zA-Z0-9\.\~\_\-] ]]; then
			output+="${char}"
		else
			printf -v hex_char "%02X" "'${char}"
			output+="%${hex_char}"
		fi
	done <<<"${input}"
	echo "${output}"
}

run_langtool() {
	for FILE in ${FILES}; do
		DATA_JSON=$(node annotate.js "${FILE}")
		ENCODED_DATA_JSON=$(urlencode "${DATA_JSON}")
		DATA_FOR_FILE="${DATA}&data=${ENCODED_DATA_JSON}"
		RESPONSE_JSON=$(curl --silent \
			--request POST \
			--data "${DATA_FOR_FILE}" \
			"${INPUT_API_ENDPOINT}/v2/check")

		# Pass the file path to tmpl
		PARSED_RESPONSE=$(echo "${RESPONSE_JSON}" | FILE="${FILE}" tmpl /langtool.tmpl)

		echo "${PARSED_RESPONSE}"
	done
}

export REVIEWDOG_GITHUB_API_TOKEN="${INPUT_GITHUB_TOKEN}"

LANGTOOL_RESPONSE=$(run_langtool)
# example
# testdata/text.md:3:10: Possible spelling mistake found. (MORFOLOGIK_RULE_EN_US)
#  Suggestions: `Joe`, `joke`, `Jake`, `eke`, `AKE`, `BKE`, `Ike`, `JCE`, `JDE`, `JE`, `JKR`, `JME`, `JNE`, `JRE`, `KE`, `GKE`, `JK`
#  Rule: https://community.languagetool.org/rule/show/MORFOLOGIK_RULE_EN_US?lang=en-US
#  Category: TYPOS
# testdata/text.md:3:14: Use “an” instead of ‘a’ if the following word starts with a vowel sound, e.g. ‘an article’, ‘an hour’. (EN_A_VS_AN)
#  Suggestions: `an`
#  URL: https://languagetool.org/insights/post/indefinite-articles/
#  Rule: https://community.languagetool.org/rule/show/EN_A_VS_AN?lang=en-US
#  Category: MISC
# testdata/text.md:7:20: Possible spelling mistake found. (MORFOLOGIK_RULE_EN_US)
#  Suggestions: `Parameter Description`
#  Rule: https://community.languagetool.org/rule/show/MORFOLOGIK_RULE_EN_US?lang=en-US
#  Category: TYPOS
# testdata/text.md:17:19: There are only 28 days in February, or 29 days during leap years. Are you sure this date is correct? (TWELFTH_OF_NEVER[9])
#  Rule: https://community.languagetool.org/rule/show/TWELFTH_OF_NEVER?lang=en-US&subId=9
#  Category: SEMANTICS
#
# Use reviewdog to filter the output and post review comments.

echo "${LANGTOOL_RESPONSE}" | reviewdog -efm="%A%f:%l:%c: %m" \
	-efm="%C %m" \
	-name="LanguageTool" \
	-reporter="${INPUT_REPORTER:-github-pr-review}" \
	-level="${INPUT_LEVEL}" \
	-filter-mode="${INPUT_FILTER_MODE}"
