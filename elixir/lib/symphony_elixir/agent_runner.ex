defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, IssueBrief, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @outcome_relative_path Path.join([".symphony", "outcome.json"])
  @prompt_provenance_relative_path Path.join([".symphony", "prompt_provenance.json"])
  @internal_artifact_relative_paths [
    @outcome_relative_path,
    @prompt_provenance_relative_path,
    Path.join([".symphony", "block_provenance.json"])
  ]

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    case finalize_reported_outcome(workspace, issue) do
      :finalized ->
        :ok

      :no_outcome ->
        with {:ok, session} <- AppServer.start_session(workspace, worker_host: worker_host) do
          try do
            do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
          after
            AppServer.stop_session(session)
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with :ok <- maybe_write_prompt_provenance(workspace, issue, turn_number),
         {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case finalize_reported_outcome(workspace, issue) do
        :no_outcome ->
          case continue_with_issue?(issue, issue_state_fetcher) do
            {:continue, refreshed_issue} when turn_number < max_turns ->
              Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

              do_run_codex_turns(
                app_session,
                workspace,
                refreshed_issue,
                codex_update_recipient,
                opts,
                issue_state_fetcher,
                turn_number + 1,
                max_turns
              )

            {:continue, refreshed_issue} ->
              Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

              :ok

            {:done, _refreshed_issue} ->
              :ok

            {:error, reason} ->
              {:error, reason}
          end

        :finalized ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp finalize_reported_outcome(workspace, %Issue{id: issue_id} = issue) when is_binary(issue_id) do
    outcome_path = Path.join(workspace, @outcome_relative_path)

    case File.read(outcome_path) do
      {:ok, body} ->
        with {:ok, payload} <- Jason.decode(body),
             {:ok, status} <- outcome_status(payload),
             {:ok, target_states} <- outcome_target_states(status, workspace) do
          case update_issue_state_candidates(issue_id, target_states) do
            :ok ->
              Logger.info("Finalized #{issue_context(issue)} from #{@outcome_relative_path} status=#{status} target_states=#{inspect(target_states)}")
              :finalized

            {:error, reason} ->
              {:error, {:outcome_state_update_failed, target_states, reason}}
          end
        else
          :no_outcome -> :no_outcome
          {:error, reason} -> {:error, {:invalid_outcome_file, outcome_path, reason}}
        end

      {:error, :enoent} ->
        :no_outcome

      {:error, reason} ->
        {:error, {:outcome_read_failed, outcome_path, reason}}
    end
  end

  defp finalize_reported_outcome(_workspace, _issue), do: :no_outcome

  defp outcome_status(%{"status" => status}) when is_binary(status) do
    normalized =
      status
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")
      |> String.replace(" ", "_")

    if normalized == "" do
      {:error, :missing_status}
    else
      {:ok, normalized}
    end
  end

  defp outcome_status(_payload), do: {:error, :missing_status}

  defp outcome_target_states(status, _workspace) when status in ["needs_merge", "merge", "merging"], do: {:ok, ["Merging", "In Review"]}

  defp outcome_target_states(status, _workspace) when status in ["needs_review", "human_review", "review", "blocked", "needs_human"],
    do: {:ok, ["Human Review", "In Review"]}

  defp outcome_target_states(status, _workspace) when status in ["continue", "in_progress"], do: :no_outcome

  defp outcome_target_states("done", workspace) do
    if git_dirty?(workspace) do
      Logger.warning("Outcome status=done but workspace is dirty; routing to Merging instead of Done workspace=#{workspace}")
      {:ok, ["Merging", "In Review"]}
    else
      {:ok, ["Done"]}
    end
  end

  defp outcome_target_states(status, _workspace), do: {:error, {:unknown_status, status}}

  defp update_issue_state_candidates(issue_id, [state_name | rest]) do
    case Tracker.update_issue_state(issue_id, state_name) do
      :ok ->
        :ok

      {:error, :state_not_found} when rest != [] ->
        update_issue_state_candidates(issue_id, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_issue_state_candidates(_issue_id, []), do: {:error, :state_not_found}

  defp git_dirty?(workspace) do
    case System.cmd("git", ["-C", workspace, "status", "--porcelain", "--untracked-files=all"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reject(&internal_artifact_status_line?/1)
        |> Enum.any?()

      _ ->
        false
    end
  end

  defp internal_artifact_status_line?(line) do
    Enum.any?(@internal_artifact_relative_paths, &String.ends_with?(line, &1))
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp maybe_write_prompt_provenance(workspace, %Issue{} = issue, 1) when is_binary(workspace) do
    settings = Config.settings!()
    compiled_issue = IssueBrief.compile(issue, max_description_chars: settings.agent.max_issue_description_chars)
    path = Path.join(workspace, @prompt_provenance_relative_path)

    payload =
      compiled_issue.provenance
      |> Map.put("issue_identifier", issue.identifier)
      |> Map.put("issue_id", issue.id)
      |> Map.put("issue_title", issue.title)
      |> Map.put("issue_state", issue.state)
      |> Map.put("issue_url", issue.url)
      |> Map.put("path", @prompt_provenance_relative_path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(payload, pretty: true)) do
      :ok
    else
      {:error, reason} -> {:error, {:prompt_provenance_write_failed, path, reason}}
    end
  end

  defp maybe_write_prompt_provenance(_workspace, _issue, _turn_number), do: :ok

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
