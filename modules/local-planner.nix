{ config, lib, pkgs, ... }:

# "Create a local plan" — planning on the big local model, with an optional
# second opinion from Claude.
#
# Same shape as modules/claude-bridge.nix, deliberately: a wrapper the agent
# calls as a tool, not a model switch. Hermes holds one model for the whole
# session, so asking it to "switch to the planner" is not a thing it can do;
# what it can do is run a command that queries a different model through
# llama-swap and hands the answer back as tool output.
#
# Three tiers, cheapest first:
#
#   local-main   every ordinary turn                    free, always loaded
#   planner      "create a local plan"                  free, ~60s to load
#   Claude       "cohort" mode, or asked for explicitly  costs subscription
#
# The planner is the tier that was missing. Before it, anything past the
# workhorse's depth went straight to a paid call.

let
  # llama-swap routes on the model name; "planner" is declared in
  # modules/llama-server.nix and loads on first request, evicting the
  # workhorse. That eviction is why this is a deliberate keyword rather than
  # something the agent reaches for casually.
  endpoint = "http://127.0.0.1:8000/v1/chat/completions";
  plannerModel = "planner";

  # The key is read from Hermes' own merged .env rather than a new file.
  # llama-swap and llama-server check the same value Hermes already holds as
  # OPENAI_API_KEY — it is literally the same secret, so a second copy would
  # add a thing to rotate without adding any isolation. That file is
  # hermes:hermes 0640 and the wrapper runs as hermes, so the read works.
  hermesEnv = "/var/lib/hermes/.hermes/.env";

  consult = "/etc/claude-bridge/consult.sh";

  plan = pkgs.writeShellScript "local-plan" ''
    set -u

    COHORT=no
    usage() {
      cat >&2 <<'USAGE'
    usage: plan.sh [--cohort] "what to plan"

    Ask the local planner model (gpt-oss-120b) for a plan. With --cohort, the
    plan is then sent to Claude for review and both are returned.

    The first call after idle loads a 59 GiB model and evicts the workhorse,
    so it takes a minute or so. Subsequent calls are fast until it times out.
    USAGE
      exit 64
    }

    while [ $# -gt 0 ]; do
      case "$1" in
        --cohort) COHORT=yes; shift ;;
        -h|--help) usage ;;
        --) shift; break ;;
        -*) usage ;;
        *) break ;;
      esac
    done
    [ "$#" -ge 1 ] || usage
    PROMPT=$*

    if [ ! -r "${hermesEnv}" ]; then
      echo "local-plan: cannot read ${hermesEnv} — are you running as the hermes user?" >&2
      exit 2
    fi
    KEY=$(${pkgs.gnused}/bin/sed -n 's/^OPENAI_API_KEY=//p' "${hermesEnv}" | ${pkgs.coreutils}/bin/head -1)
    if [ -z "$KEY" ]; then
      echo "local-plan: no OPENAI_API_KEY in ${hermesEnv}" >&2
      exit 2
    fi

    SYSTEM='You are a planning model. Produce a concrete, ordered plan: the steps, their dependencies, and the decisions that have to be made before starting. Name the risks that would change the plan. Do not write implementation code. Be specific and compact.'

    body=$(${pkgs.jq}/bin/jq -n --arg s "$SYSTEM" --arg p "$PROMPT" --arg m "${plannerModel}" \
      '{model:$m, messages:[{role:"system",content:$s},{role:"user",content:$p}], max_tokens:2000, stream:false}')

    # Long timeout on purpose: a cold planner load is a 59 GiB model coming off
    # disk, and failing at 60s would make the tier unusable exactly when it is
    # first reached.
    resp=$(${pkgs.curl}/bin/curl -sS -m 900 \
      -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
      -d "$body" "${endpoint}" 2>&1)

    PLAN=$(printf '%s' "$resp" | ${pkgs.jq}/bin/jq -r '.choices[0].message.content // empty' 2>/dev/null)
    if [ -z "$PLAN" ]; then
      echo "local-plan: no plan came back. Raw response follows." >&2
      printf '%s\n' "$resp" | ${pkgs.coreutils}/bin/head -c 800 >&2
      exit 1
    fi

    printf '=== LOCAL PLAN (%s) ===\n%s\n' "${plannerModel}" "$PLAN"

    [ "$COHORT" = yes ] || exit 0

    # Cohort mode: the local plan goes to Claude for review rather than being
    # regenerated. Reviewing a concrete plan is a much cheaper question than
    # producing one, and it keeps the local model as the author.
    if [ ! -x "${consult}" ]; then
      echo "" >&2
      echo "local-plan: --cohort needs ${consult}, which is missing" >&2
      exit 1
    fi

    REVIEW="Another model produced the plan below. Review it: what is wrong, what is missing, and what would you do differently? Be specific and brief. If the plan is sound, say so plainly rather than inventing objections.

    --- PLAN ---
    $PLAN"

    printf '\n=== CLAUDE REVIEW ===\n'
    ${consult} "$REVIEW"
  '';

  skill = ''
    ---
    name: local-plan
    description: Produce a plan using the big local planner model. Triggered by "create a local plan". Add cohort mode to have Claude review the plan afterwards.
    version: 1.0.0
    license: MIT
    platforms: [linux]
    metadata:
      hermes:
        tags: [planning, architecture, local]
        category: local
        requires_toolsets: [terminal]
    ---

    # Planning tiers on this box

    Three tiers. Use the cheapest one that can answer.

    | Tier | Reach for it | Cost |
    | --- | --- | --- |
    | you (local-main) | ordinary work, most questions | free, already loaded |
    | `plan.sh` | the user says **"create a local plan"** | free, ~1 min to load |
    | `plan.sh --cohort` | the user says **"cohort"** | subscription call |
    | `consult.sh` | stuck, or explicitly asked for Claude | subscription call |

    ## Call it

    ```bash
    /etc/local-planner/plan.sh "what to plan, with the constraints inline"
    /etc/local-planner/plan.sh --cohort "same, plus a Claude review of the plan"
    ```

    Both print to stdout. `--cohort` prints the local plan first, then Claude's
    review of that plan underneath.

    ## What the keywords mean

    **"create a local plan"** means run `plan.sh` — the planner is a much
    larger model than you and it is worth its load time for a genuine planning
    question. Do not paraphrase its output as your own; show it, then say what
    you would do with it.

    **"cohort"** means `--cohort`: the local planner drafts and Claude reviews.
    Use it when the user wants the plan checked, not when they want a plan.

    ## Cost, and why it is not free

    The planner is 59 GiB. Loading it evicts the workhorse — you — from memory,
    and coming back costs a reload too. So it is worth a real planning question
    and wasteful for a question you can answer. One call per planning task,
    with everything the planner needs in the prompt, beats three exploratory
    calls.

    Each call is stateless. Include the constraints, what has been tried, and
    the decision actually pending. The planner cannot see this conversation.
  '';
in
{
  environment.etc."local-planner/plan.sh" = {
    source = plan;
    mode = "0555";
  };

  services.hermes-agent.hermesHomeFiles."skills/local/local-plan/SKILL.md" = skill;
}
