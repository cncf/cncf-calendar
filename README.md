# CNCF Calendar

A GitHub Action and static site generator for listing CNCF (Cloud Native Computing Foundation) projects and their calendars, grouped by category, with a search interface.

## Overview

This project fetches project data from the Linux Foundation API and generates a modern, searchable HTML page listing CNCF projects by category (TAG, Graduated, Incubating, and Sandbox). Each project entry includes its logo, name, calendar link, and repository link (if available).

The generated site is suitable for publishing as a GitHub Pages site or for use in other static hosting environments.

## Features
- **Automated Data Fetching:** Uses the LFX API to retrieve up-to-date CNCF project information.
- **Categorized Listing:** Projects are grouped and sorted by their CNCF category.
- **Modern UI:** Clean, responsive HTML with a search box for filtering projects.
- **Easy Integration:** Designed for use in CI/CD pipelines (e.g., GitHub Actions).

## Usage

### Prerequisites
- **jq**: Command-line JSON processor (required by the script)
- **curl**: For API requests
- **Bash**: The script uses bash-specific features
- **LFX_TOKEN**: For manual runs, provide a valid LFX V2 API token. GitHub Actions mints one at runtime from organization credentials.

### Running the Script

1. **Set the LFX_TOKEN environment variable:**
   ```sh
   export LFX_TOKEN=your_lfx_api_token_here
   ```
2. **Run the script:**
   ```sh
   bash calendar_update/entrypoint.sh
   ```
   The script will generate an `index.html` file in the repository root (or in the directory specified by `$GITHUB_WORKSPACE`).

### GitHub Actions
This script is designed to be used as part of a GitHub Action workflow. The workflow supports manual dispatch and runs daily at `06:00 UTC`. It mints a short-lived production V2 token from the `LFX_PROD_CLIENT_ID` and `LFX_PROD_CLIENT_SECRET` organization secrets. A repository-level `LFX_TOKEN` secret is not required.

## File Structure
- `calendar_update/entrypoint.sh`: Main script for fetching data and generating HTML
- `calendar_update/mint_lfx_token.sh`: Mints a short-lived LFX V2 API token in GitHub Actions
- `index.html`: Output file with the project calendar listing
- `calendar_update/action.yaml`: (If present) GitHub Action metadata

## Customization
- **Project scope:** The script finds the V2 project with the `cncf` slug and retrieves its child projects.
- **Styling:** Edit the HTML/CSS in the script for custom branding or layout.

## Contributing
Pull requests and issues are welcome! Please ensure your code is well-commented and tested.

## License
[Apache-2.0](LICENSE)


