#!/bin/bash
# entrypoint.sh
#
# Fetches CNCF project data from the LFX API, processes it, and generates an
# HTML file listing projects by category. Expects LFX_TOKEN and GITHUB_WORKSPACE
# to be set (designed to run inside a GitHub Action).

set -euo pipefail

# Initialize empty BEFORE registering the trap, so cleanup() never runs on an
# unset variable if the script exits before the temp file is created.
FORMING_PROJECTS_TEMP_FILE=""
cleanup() {
    [ -n "${FORMING_PROJECTS_TEMP_FILE:-}" ] && rm -f "$FORMING_PROJECTS_TEMP_FILE"
}
trap cleanup EXIT

if [ -z "${LFX_TOKEN:-}" ]; then
    echo "Error: The LFX_TOKEN environment variable is not set." >&2
    exit 1
fi

if [ -z "${GITHUB_WORKSPACE:-}" ]; then
    echo "Error: GITHUB_WORKSPACE is not set (this script expects to run inside GitHub Actions)." >&2
    exit 1
fi

BASE_API_URL="https://api-gw.platform.linuxfoundation.org/project-service/v1/projects"
OUTPUT_HTML_FILE="${GITHUB_WORKSPACE}/index.html"
PAGE_SIZE=100
FOUNDATION_ID="a0941000002wBz4AAE" # CNCF Foundation ID
FORMING_PROJECTS_STATUS="Formation - Exploratory"
CURL_MAX_TIME=30
CURL_MAX_RETRIES=3

FORMING_PROJECTS_TEMP_FILE=$(mktemp)

# JQ processors. @html escapes Name/ProjectLogo/RepositoryURL to prevent broken
# attributes / HTML injection from externally sourced API data. RepositoryURL is
# additionally validated with test("^https?://") before being used as an href.
JQ_HTML_PROCESSOR='
def category_rank:
  if .Category == "TAG" then 1
  elif .Category == "Graduated" then 2
  elif .Category == "Incubating" then 3
  elif .Category == "Sandbox" then 4
  else 0
  end;
[inputs] |
map(. + {category_sort_key: category_rank}) |
map(select(.category_sort_key > 0)) |
sort_by([.category_sort_key, .Name]) |
group_by(.Category) |
sort_by(.[0].category_sort_key) |
map(
    (.[0].Category) as $current_category_name |
    "<h2>" + (if $current_category_name == "TAG" then "TOC Technical Advisory Groups (TAG)" else $current_category_name end) + " (" + (length | tostring) + ")</h2>\n" +
    (if $current_category_name == "TAG" then "<p>CNCF Technical Oversight Committee (TOC) meetings can be found on the <a href=\"https://zoom-lfx.platform.linuxfoundation.org/meetings/cncf?projects=cncf&view=week\">CNCF Main calendar (Project calendar)</a></p>" else "" end) +
    "<ul class=\"project-list\">\n" +
    (map(
        "<li class=\"project-item\"><img src=\"" + (((.ProjectLogo | select(length > 0)) // "https://lf-master-project-logos-prod.s3.us-east-2.amazonaws.com/cncf.svg") | @html) + "\" alt=\"" + (.Name | @html) + " Logo\" class=\"project-logo\"> " + (.Name | @html) + " (<a href=\"https://zoom-lfx.platform.linuxfoundation.org/meetings/" + (.Slug | @uri) + "\">Project calendar</a>)" +
        (if .RepositoryURL and (.RepositoryURL | length > 0) and (.RepositoryURL | test("^https?://")) then " (<a href=\"" + (.RepositoryURL | @html) + "\">Project code</a>)" else "" end) +
        "</li>\n"
    ) | add) +
    "</ul>\n"
) | add
'

JQ_FORMING_PROJECTS_PROCESSOR='
. |
sort_by(.Name) |
(length) as $project_count |
"<h2>Forming Projects (" + ($project_count | tostring) + ")</h2>\n<ul class=\"project-list\">\n" +
(map(
    "<li class=\"project-item\"><img src=\"" + (((.ProjectLogo | select(length > 0)) // "https://lf-master-project-logos-prod.s3.us-east-2.amazonaws.com/cncf.svg") | @html) + "\" alt=\"" + (.Name | @html) + " Logo\" class=\"project-logo\"> " + (.Name | @html) +
    (if .RepositoryURL and (.RepositoryURL | length > 0) and (.RepositoryURL | test("^https?://")) then " (<a href=\"" + (.RepositoryURL | @html) + "\">GitHub</a>)" else "" end) +
    "</li>\n"
) | add) +
"</ul>\n"
'

# Function: Print the HTML header and search box
print_html_header() {
    cat <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>CNCF Projects</title>
    <meta charset="utf-8">
    <style>
    body { font-family: Arial, sans-serif; margin: 20px; line-height: 1.6; background-color: #f4f7f6; }
    h1 { color: #2c3e50; text-align: center; margin-bottom: 30px; font-size: 2.5em; padding-bottom: 10px; border-bottom: 3px solid #3498db;}
    h2 { color: #34495e; border-bottom: 1px solid #bdc3c7; padding-bottom: 8px; margin-top: 30px; font-size: 1.8em; }
    ul { list-style-type: none; padding: 0; margin-left: 20px; }
    li {
        margin-bottom: 5px;
        font-size: 1.1em;
        background-color: #ffffff;
        padding: 5px 10px;
        border-radius: 5px;
        box-shadow: 0 2px 4px rgba(0,0,0,0.05);
    }
    a { color: #3498db; text-decoration: none; }
    a:hover { text-decoration: underline; color: #2980b9; }
    #search-box {
        width: 50%;
        padding: 10px;
        margin-bottom: 20px;
        border: 1px solid #ccc;
        border-radius: 5px;
        box-sizing: border-box;
        font-size: 1.1em;
    }
    .project-logo {
        width: 60px;
        height: 60px;
        vertical-align: middle;
        margin-right: 5px;
        object-fit: contain;
    }
    .main-cncf-logo {
        width: 60px !important;
        height: 60px !important;
        vertical-align: middle;
        margin-right: 8px;
        object-fit: contain;
    }
</style>
</head>
<body>
    <h1> </h1>
    <h2>Main Calendar</h2>
    <ul>
        <li><img src="https://lf-master-project-logos-prod.s3.us-east-2.amazonaws.com/cncf.svg" alt="CNCF Logo" width="200" height="200" style="vertical-align: middle; margin-right: 16px; object-fit: contain;"> CNCF Main calendar (<a href="https://zoom-lfx.platform.linuxfoundation.org/meetings/cncf">Project calendar</a>)</li>
    </ul>
    <input type="text" id="search-box" onkeyup="filterProjects()" placeholder="Search for projects...">
    <script>
        function filterProjects() {
            let input = document.getElementById('search-box');
            let filter = input.value.toUpperCase();
            let projectLists = document.getElementsByClassName('project-list');
            for (let i = 0; i < projectLists.length; i++) {
                let ul = projectLists[i];
                let li = ul.getElementsByClassName('project-item');
                let categoryHasVisibleProjects = false;
                for (let j = 0; j < li.length; j++) {
                    let projectItem = li[j];
                    let textValue = projectItem.textContent || projectItem.innerText;
                    if (textValue.toUpperCase().indexOf(filter) > -1) {
                        projectItem.style.display = "flex";
                        categoryHasVisibleProjects = true;
                    } else {
                        projectItem.style.display = "none";
                    }
                }
                let h2 = ul.previousElementSibling;
                if (h2 && h2.tagName === 'H2') {
                    h2.style.display = categoryHasVisibleProjects ? "" : "none";
                }
            }
        }
    </script>
EOF
}

# Function: Print the HTML footer
print_html_footer() {
    cat <<EOF
</body>
</html>
EOF
}

# Fetch all paginated project data from the API.
# --fail makes an HTTP 4xx/5xx count as a curl failure; failed requests are
# retried with backoff; and if they still fail, the script exits (1) instead of
# silently breaking out of the loop and publishing an incomplete page.
fetch_all_projects() {
    local offset=0
    while true; do
        local current_api_url="${BASE_API_URL}?offset=${offset}&limit=${PAGE_SIZE}"
        local response=""
        local retry_count=0

        while [ "$retry_count" -lt "$CURL_MAX_RETRIES" ]; do
            if response=$(curl -sS --fail --max-time "$CURL_MAX_TIME" \
                -H "Authorization: Bearer $LFX_TOKEN" \
                "$current_api_url"); then
                break
            fi
            retry_count=$((retry_count + 1))
            echo "Warning: LFX API request failed (offset=$offset), retry $retry_count/$CURL_MAX_RETRIES..." >&2
            sleep $((retry_count * 2))
        done

        if [ "$retry_count" -eq "$CURL_MAX_RETRIES" ]; then
            echo "Error: LFX API request failed after $CURL_MAX_RETRIES retries (offset=$offset). Aborting." >&2
            exit 1
        fi

        if ! echo "$response" | jq -e '.Data' > /dev/null 2>&1; then
            echo "Error: Invalid JSON response or 'Data' array missing for offset $offset. Aborting." >&2
            exit 1
        fi

        local projects_received_on_page
        projects_received_on_page=$(echo "$response" | jq '.Data | length')
        if [ "$projects_received_on_page" -eq 0 ]; then
            break
        fi

        # Output main category projects as JSON lines.
        # --arg avoids interpolating shell variables directly into the jq program.
        echo "$response" | jq -c --arg fid "$FOUNDATION_ID" \
            '.Data[] | select(.Foundation.ID == $fid and .Status == "Active") | {Name: .Name, Slug: .Slug, Category: .Category, ProjectLogo: .ProjectLogo, RepositoryURL: .RepositoryURL}'

        # Output forming projects to temp file
        local forming_json
        forming_json=$(echo "$response" | jq -c --arg fid "$FOUNDATION_ID" --arg status "$FORMING_PROJECTS_STATUS" \
            '.Data[] | select(.Foundation.ID == $fid and .Status == $status) | {Name: .Name, ProjectLogo: .ProjectLogo, RepositoryURL: .RepositoryURL}')
        if [ -n "$forming_json" ]; then
            echo "$forming_json" >> "$FORMING_PROJECTS_TEMP_FILE"
        fi

        offset=$((offset + projects_received_on_page))
        sleep 0.2
    done
}

# Function: Generate HTML for main project categories using jq
generate_main_categories_html() {
    jq -n -r "$JQ_HTML_PROCESSOR"
}

# Function: Generate HTML for forming projects using jq
generate_forming_projects_html() {
    if [ -s "$FORMING_PROJECTS_TEMP_FILE" ]; then
        jq -s '.' "$FORMING_PROJECTS_TEMP_FILE" | jq -r "$JQ_FORMING_PROJECTS_PROCESSOR"
    else
        # Use printf, not echo: echo without -e printed "\n" as a literal string.
        printf '<h2>Forming Projects (0)</h2>\n<ul class="project-list">\n</ul>\n'
    fi
}

# Main execution: generate HTML file
{
    print_html_header
    # Fetch and process all projects, pipe to jq for main categories
    fetch_all_projects | generate_main_categories_html
    # Generate forming projects section
    generate_forming_projects_html
    print_html_footer
} > "$OUTPUT_HTML_FILE"

# Log summary and set GitHub Action output
TOTAL_FORMING_PROJECTS_FINAL_COUNT=0
if [ -s "$FORMING_PROJECTS_TEMP_FILE" ]; then
    TOTAL_FORMING_PROJECTS_FINAL_COUNT=$(wc -l < "$FORMING_PROJECTS_TEMP_FILE")
fi

TOTAL_PROJECT_ITEMS=$(grep -o 'class="project-item"' "$OUTPUT_HTML_FILE" | wc -l || true)

# Sanity check: if no project at all was found (main or forming), something went
# wrong upstream (token, API schema, filter). Fail instead of silently
# publishing an empty page.
if [ "$TOTAL_PROJECT_ITEMS" -eq 0 ]; then
    echo "Error: No projects found in the API response. Aborting to avoid publishing an empty page." >&2
    exit 1
fi

echo "Total project items in the generated page (all categories): $TOTAL_PROJECT_ITEMS"
echo "Total 'Formation - Exploratory' projects identified: $TOTAL_FORMING_PROJECTS_FINAL_COUNT"
echo "HTML file generated: $OUTPUT_HTML_FILE"
echo "html_file=${OUTPUT_HTML_FILE}" >> "$GITHUB_OUTPUT"
