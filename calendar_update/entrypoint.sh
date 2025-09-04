#!/bin/bash
# entrypoint.sh
#
# This script fetches CNCF project data from the LFX API, processes it, and generates an HTML file listing projects by category.
# It is designed for use in a GitHub Action and expects the LFX_TOKEN environment variable to be set.

# Strict error handling: exit on error, unset variable, or failed pipeline
set -euo pipefail

# Trap to ensure temp files are cleaned up on exit or error
cleanup() {
    rm -f "$FORMING_PROJECTS_TEMP_FILE"
}
trap cleanup EXIT

# 1. TOKEN VALIDATION: Read the token from an environment variable.
if [ -z "${LFX_TOKEN:-}" ]; then
    echo "Error: The LFX_TOKEN environment variable is not set." >&2
    exit 1
fi

# API and HTML settings
BASE_API_URL="https://api-gw.platform.linuxfoundation.org/project-service/v1/projects"
OUTPUT_HTML_FILE="${GITHUB_WORKSPACE}/index.html"
PAGE_SIZE=100
OFFSET=0
FOUNDATION_ID="a0941000002wBz4AAE" # CNCF Foundation ID
FORMING_PROJECTS_STATUS="Formation - Exploratory"
FORMING_PROJECTS_TEMP_FILE=$(mktemp)

# JQ processors for HTML generation
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
map(select(select(.category_sort_key > 0))) |
sort_by([.category_sort_key, .Name]) |
group_by(.Category) |
sort_by(.[0].category_sort_key) |
map(
    (.[0].Category) as $current_category_name |
    "<h2>" + (if $current_category_name == "TAG" then "TOC Technical Advisory Groups (TAG)" else $current_category_name end) + " (" + (length | tostring) + ")</h2>\n" +
    (if $current_category_name == "TAG" then "<p>CNCF Technical Oversight Committee (TOC) meetings can be found on the <a href=\"https://zoom-lfx.platform.linuxfoundation.org/meetings/cncf?projects=cncf&view=week\">CNCF Main calendar (Project calendar)</a></p>" else "" end) +
    "<ul class=\"project-list\">\n" +
    (map(
        "<li class=\"project-item\"><img src=\"" + ((.ProjectLogo | select(length > 0)) // "https://lf-master-project-logos-prod.s3.us-east-2.amazonaws.com/cncf.svg") + "\" alt=\"" + .Name + " Logo\" class=\"project-logo\"> " + .Name + " (<a href=\"https://zoom-lfx.platform.linuxfoundation.org/meetings/" + (.Slug | @uri) + "\">Project calendar</a>)" +
        (if .RepositoryURL and (.RepositoryURL | length > 0) then " (<a href=\"" + .RepositoryURL + "\">Project code</a>)" else "" end) +
        "</li>\n"
    ) | add) +
    "</ul>\n"
) | add
'

JQ_FORMING_PROJECTS_PROCESSOR='
. | # Expects an array as input
sort_by(.Name) |
# Now map the array to HTML, including the count (length of the array)
(length) as $project_count |
"<h2>Forming Projects (" + ($project_count | tostring) + ")</h2>\n<ul class=\"project-list\">\n" +
(map(
    "<li class=\"project-item\"><img src=\"" + ((.ProjectLogo | select(length > 0)) // "https://lf-master-project-logos-prod.s3.us-east-2.amazonaws.com/cncf.svg") + "\" alt=\"" + .Name + " Logo\" class=\"project-logo\"> " + .Name +
    (if .RepositoryURL and (.RepositoryURL | length > 0) then " (<a href=\"" + .RepositoryURL + "\">GitHub</a>)" else "" end) +
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

# Function: Fetch all paginated project data from the API
fetch_all_projects() {
    local offset=0
    while true; do
        local current_api_url="${BASE_API_URL}?offset=${offset}&limit=${PAGE_SIZE}"
        local response
        response=$(curl -sS -H "Authorization: Bearer $LFX_TOKEN" "$current_api_url")

        # Validate JSON and presence of .Data
        if ! echo "$response" | jq -e '.Data' > /dev/null 2>&1; then
            echo "Error: Invalid JSON response or 'Data' array not found for offset $offset." >&2
            break
        fi

        local projects_received_on_page
        projects_received_on_page=$(echo "$response" | jq '.Data | length')
        if [ "$projects_received_on_page" -eq 0 ]; then
            break
        fi

        # Output main category projects as JSON lines
        echo "$response" | jq -c '.Data[] | select(.Foundation.ID == "'"$FOUNDATION_ID"'" and .Status == "Active") | {Name: .Name, Slug: .Slug, Category: .Category, ProjectLogo: .ProjectLogo, RepositoryURL: .RepositoryURL}'

        # Output forming projects to temp file
        local forming_json
        forming_json=$(echo "$response" | jq -c '.Data[] | select(.Foundation.ID == "'"$FOUNDATION_ID"'" and .Status == "'"$FORMING_PROJECTS_STATUS"'") | {Name: .Name, ProjectLogo: .ProjectLogo, RepositoryURL: .RepositoryURL}')
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
        cat "$FORMING_PROJECTS_TEMP_FILE" | jq -s '.' | jq -r "$JQ_FORMING_PROJECTS_PROCESSOR"
    else
        echo "<h2>Forming Projects (0)</h2>\n<ul class=\"project-list\">\n</ul>"
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
TOTAL_FORMING_PROJECTS_FINAL_COUNT=$(if [ -s "$FORMING_PROJECTS_TEMP_FILE" ]; then cat "$FORMING_PROJECTS_TEMP_FILE" | wc -l; else echo 0; fi)
echo "Total projects matching Foundation ID filter (main categories): (count from HTML if accurate, or 0 if from subshell)"
echo "Total 'Formation - Exploratory' projects identified: $TOTAL_FORMING_PROJECTS_FINAL_COUNT"
echo "HTML file generated: $OUTPUT_HTML_FILE"
echo "html_file=${OUTPUT_HTML_FILE}" >> "$GITHUB_OUTPUT"
