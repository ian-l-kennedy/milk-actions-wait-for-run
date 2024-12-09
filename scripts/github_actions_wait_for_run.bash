#!/usr/bin/env bash

if ! command -v curl > /dev/null; then
    echo "FAILURE: 'curl' is not installed or not available in PATH. Please install curl to proceed."
    exit 1
fi

milk_url="https://raw.githubusercontent.com/ian-l-kennedy"
milk_bash="${milk_url}/milk-bash/refs/heads/main/src/milk.bash"
if ! curl --head --silent --fail "${milk_bash}" > /dev/null; then
    echo "FAILURE: Cannot connect to bash script source dependency: ${milk_bash}."
    exit 1
fi

source <(curl --silent "${milk_bash}")

set -e
set -o pipefail
set -u

NOTICE "Executing github_actions_wait_for_run.bash..."

REQUIRE_COMMAND jq

INFO "Processing the command line parameters..."

# Default values
mimic_input_conclusion=""
base_url=""
owner=""
repo=""
workflow_run_id=""
outer_retry_limit=60
outer_retry_delay=300
github_token=""

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mimic_input_conclusion) mimic_input_conclusion="$2"; shift 2 ;;
    --base-url) base_url="$2"; shift 2 ;;
    --owner) owner="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --workflow-run-id) workflow_run_id="$2"; shift 2 ;;
    --outer-retry-limit) outer_retry_limit="$2"; shift 2 ;;
    --outer-retry-delay) outer_retry_delay="$2"; shift 2 ;;
    --github-token) github_token="$2"; shift 2 ;;
    *) echo "Unknown option $1"; exit 1 ;;
  esac
done

desc_mimic_input_conclusion="The regular expression to gather job names (--mimic_input_conclusion)"
desc_base_url="The base URL of the GitHub repository (e.g., https://api.github.com) (--base-url)"
desc_owner="The owner of the GitHub repository (e.g., username or organization name) (--owner)"
desc_repo="The name of the GitHub repository (--repo)"
desc_workflow_run_id="The ID of the workflow where this action is invoked (--workflow-run-id)"
desc_outer_retry_limit="The maximum number of iterations for the outer loop (--outer-retry-limit)"
desc_outer_retry_delay="The delay in seconds for each outer loop iteration (--outer-retry-delay)"

# Validate required parameters
if [[ -z "$github_token" ]]; then
  ERROR "Missing required parameter: --github-token. A GitHub personal access token is needed."
  exit 1
fi

if [[ -z "$mimic_input_conclusion" ]]; then
  ERROR "Missing required parameter: $desc_mimic_input_conclusion"
  exit 1
elif [[ "$mimic_input_conclusion" == "" ]]; then
  ERROR "Required parameter is present but is blank: $desc_mimic_input_conclusion"
  exit 1
fi

if [[ -z "$base_url" ]]; then
  ERROR "Missing required parameter: $desc_base_url"
  exit 1
elif [[ "$base_url" == "" ]]; then
  ERROR "Required parameter is present but is blank: $desc_base_url"
  exit 1
fi

if [[ -z "$owner" ]]; then
  ERROR "Missing required parameter: $desc_owner"
  exit 1
elif [[ "$owner" == "" ]]; then
  ERROR "Required parameter is present but is blank: $desc_owner"
  exit 1
fi

if [[ -z "$repo" ]]; then
  ERROR "Missing required parameter: $desc_repo"
  exit 1
elif [[ "$repo" == "" ]]; then
  ERROR "Required parameter is present but is blank: $desc_repo"
  exit 1
fi

if [[ -z "$workflow_run_id" ]]; then
  ERROR "Missing required parameter: $desc_workflow_run_id"
  exit 1
elif [[ "$workflow_run_id" == "" ]]; then
  ERROR "Required parameter is present but is blank: $desc_workflow_run_id"
  exit 1
fi

if ! [[ "$outer_retry_limit" =~ ^[0-9]+$ ]] || ! [[ "$outer_retry_delay" =~ ^[0-9]+$ ]]; then
  ERROR "Parameters outer_retry_limit and outer_retry_delay must be positive integers."
  exit 1
fi

INFO "Running with:"
INFO "  Mimic Conclusion: $mimic_input_conclusion"
INFO "  Base URL: $base_url"
INFO "  Owner: $owner"
INFO "  Repo: $repo"
INFO "  Workflow ID: $workflow_run_id"
INFO "  Outer Retry Limit: $outer_retry_limit"
INFO "  Outer Retry Delay: $outer_retry_delay"

# Setup a unique log file
LOG_FILE="/tmp/action_log_milk_actions_wait_for_run_${workflow_run_id}_$$.txt"

if ! touch "$LOG_FILE"; then
    echo "LOG ERROR: Failed to create log file: $LOG_FILE"
    exit 1
fi

if [[ ! -w "$LOG_FILE" ]]; then
    echo "LOG ERROR: Log file is not writable: $LOG_FILE"
    exit 1
fi

INFO "Log file created: $LOG_FILE"

INFO "Defining functions..."

# Redirect logging functions to the log file
LOGGER_NOTICE() {
  if [[ -w "$LOG_FILE" || ! -e "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]]; then
    NOTICE "$*" >> "$LOG_FILE"
  else
    echo "LOG ERROR: Cannot write to log file: $LOG_FILE"
  fi
}

LOGGER_INFO() {
  if [[ -w "$LOG_FILE" || ! -e "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]]; then
    INFO "$*" >> "$LOG_FILE"
  else
    echo "LOG ERROR: Cannot write to log file: $LOG_FILE"
  fi
}

LOGGER_WARN() {
  if [[ -w "$LOG_FILE" || ! -e "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]]; then
    WARN "$*" >> "$LOG_FILE"
  else
    echo "LOG ERROR: Cannot write to log file: $LOG_FILE"
  fi
}

LOGGER_ERROR() {
  if [[ -w "$LOG_FILE" || ! -e "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]]; then
    ERROR "$*" >> "$LOG_FILE"
  else
    echo "LOG ERROR: Cannot write to log file: $LOG_FILE"
  fi
}

# Function to display logs after each function call
display_log() {
  cat "$LOG_FILE"
}


clear_log() {
    if [[ -w "$LOG_FILE" ]]; then
        > "$LOG_FILE"
    else
        echo "LOG ERROR: Cannot clear log file: $LOG_FILE"
    fi
}

clear_log

trap display_log EXIT

fetch_run_status() {
    local run_id="$1"
    local response

    LOGGER_INFO "Fetching status for workflow run ID: $run_id"
    LOGGER_INFO "Making API request to: ${base_url}/repos/${owner}/${repo}/actions/runs/${run_id}"

    response=$(curl -s -H "Authorization: Bearer $github_token" \
        -H "Accept: application/vnd.github.v3+json" \
        "${base_url}/repos/${owner}/${repo}/actions/runs/${run_id}")

    if [[ -z "$response" ]]; then
        LOGGER_ERROR "Empty response from GitHub API for workflow run ID: $run_id"
        return 1
    fi

    LOGGER_INFO "Raw response received from GitHub API:"
    LOGGER_INFO "$response"

    if ! echo "$response" | jq -e . > /dev/null 2>&1; then
        LOGGER_ERROR "Invalid JSON response received for workflow run ID: $run_id. Response: $response"
        return 1
    fi

    # Parse the `status` and `conclusion` fields
    local status conclusion
    status=$(echo "$response" | jq -r '.status // "null"')
    conclusion=$(echo "$response" | jq -r '.conclusion // "null"')

    LOGGER_INFO "Parsed status: $status"
    LOGGER_INFO "Parsed conclusion: $conclusion"

    if [[ "$status" == "null" ]]; then
        LOGGER_ERROR "The status field is null or not present in the response for workflow run ID: $run_id. Response: $response"
        return 1
    fi

    if [[ "$status" == "queued" ]]; then
        LOGGER_INFO "Workflow run ID: $run_id is in queued state with no conclusion available."
        conclusion="null"  # Ensure conclusion is explicitly null for queued status
    fi

    if [[ "$status" == "completed" && "$conclusion" == "null" ]]; then
        LOGGER_WARN "Workflow run ID: $run_id is marked as completed but has no conclusion. Treating it as failure."
        conclusion="failure"  # Assume failure if completed without a conclusion
    fi

    LOGGER_INFO "Returning status: $status, conclusion: $conclusion"
    echo "$status" "$conclusion"
    return 0
}


INFO "main..."

INFO "Starting to poll GitHub API for workflow run status..."

retry_count=0
while [[ $retry_count -lt $outer_retry_limit ]]; do
    set +e
    fetch_run_status_output=$(fetch_run_status "$workflow_run_id" 2>&1)
    fetch_run_status_result=$?
    set -e

    display_log
    clear_log

    if [[ $fetch_run_status_result -ne 0 ]]; then
        ERROR "Failed to fetch run status for workflow ID: $workflow_run_id. Output: $fetch_run_status_output"
        INFO "Retrying after $outer_retry_delay seconds..."
        retry_count=$((retry_count + 1))
        sleep "$outer_retry_delay"
        continue
    fi

    # Parse the output from fetch_run_status
    read -r status conclusion <<< "$fetch_run_status_output"

    if [[ "$status" == "pending" || "$status" == "queued" || "$status" == "in_progress" ]]; then
        INFO "Workflow run is still ongoing. Current status: $status, Conclusion: $conclusion (if any)."
        INFO "Waiting for $outer_retry_delay seconds before retrying..."
        retry_count=$((retry_count + 1))
        sleep "$outer_retry_delay"
        continue
    fi

    if [[ "$status" == "completed" ]]; then
        if [[ "$mimic_input_conclusion" == "true" ]]; then
            if [[ "$conclusion" == "success" ]]; then
                NOTICE "Workflow run completed successfully."
                exit 0
            else
                NOTICE "Workflow run completed with conclusion: $conclusion"
                exit 1
            fi
        else
            NOTICE "Workflow run completed. Mimic conclusion is disabled. Passing regardless of result."
            exit 0
        fi
    fi

    INFO "Unexpected status: $status. Retrying after $outer_retry_delay seconds..."
    retry_count=$((retry_count + 1))
    sleep "$outer_retry_delay"
done

ERROR "Reached retry limit ($outer_retry_limit). Workflow run did not complete in time."
exit 1
