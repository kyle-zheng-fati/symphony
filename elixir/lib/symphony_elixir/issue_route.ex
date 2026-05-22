defmodule SymphonyElixir.IssueRoute do
  @moduledoc """
  Compiles tracker issues into typed orchestration routes.

  `IssueBrief` owns bounded prompt context. This module owns dispatch
  eligibility. The DSPy route signature inherits the brief/input shape so route
  provenance can point at the exact composition layer without mixing routing
  policy into prompt rendering.
  """

  alias SymphonyElixir.Linear.Issue

  @signature_version "SymphonyIssueRouteV1"
  @parent_signatures ["SymphonyIssueInputV1", "SymphonyIssueBriefV1"]
  @input_fields ["identifier", "title", "state", "labels", "url", "description"]
  @output_fields [
    "owner_pool",
    "eligible_pools",
    "route_tags",
    "route_reason",
    "confidence",
    "human_escalation"
  ]
  @dspy_script Path.expand("../../../../scripts/symphony-dspy-issue-route.py", __DIR__)

  @type route :: %{
          owner_pool: String.t(),
          eligible_pools: [String.t()],
          route_tags: [String.t()],
          route_reason: String.t(),
          confidence: float(),
          human_escalation: boolean()
        }

  @type compiled :: %{
          route: route(),
          provenance_text: String.t(),
          provenance: map()
        }

  @spec compile(Issue.t(), keyword()) :: compiled()
  def compile(%Issue{} = issue, opts \\ []) do
    brief_provenance =
      opts
      |> Keyword.get(:compiled_issue)
      |> brief_provenance()

    case issue_route_compiler() do
      :dspy ->
        case compile_with_dspy(issue, brief_provenance) do
          {:ok, compiled} -> compiled
          {:error, reason} -> compile_elixir(issue, reason)
        end

      :dspy_required ->
        case compile_with_dspy(issue, brief_provenance) do
          {:ok, compiled} -> compiled
          {:error, reason} -> raise RuntimeError, "dspy_issue_route_failed: #{inspect(reason)}"
        end

      :elixir ->
        compile_elixir(issue)
    end
  end

  @spec codex_eligible?(Issue.t()) :: boolean()
  def codex_eligible?(%Issue{} = issue) do
    issue
    |> compile()
    |> get_in([:route, :eligible_pools])
    |> case do
      pools when is_list(pools) -> "codex" in pools
      _ -> true
    end
  end

  defp compile_elixir(%Issue{} = issue, fallback_reason \\ nil) do
    route = route_issue(issue)

    provenance =
      %{
        "signature" => @signature_version,
        "parent_signatures" => @parent_signatures,
        "compiler" => "symphony_elixir.issue_route",
        "compiler_contract" => "dspy-compatible-signature.inherited",
        "input_fields" => @input_fields,
        "output_fields" => @output_fields,
        "owner_pool" => route.owner_pool,
        "eligible_pools" => route.eligible_pools,
        "route_tags" => route.route_tags,
        "route_reason" => route.route_reason,
        "confidence" => route.confidence,
        "human_escalation" => route.human_escalation,
        "hierarchy" => @parent_signatures ++ [@signature_version],
        "separation_of_concerns" => %{
          "issue_brief" => "bounded prompt context",
          "issue_route" => "dispatch eligibility and owner pool",
          "symphony" => "state reconciliation, workspace execution, and runtime guards"
        }
      }
      |> maybe_put_fallback_reason(fallback_reason)

    %{route: route, provenance_text: render_provenance(provenance), provenance: provenance}
  end

  defp route_issue(%Issue{} = issue) do
    labels = normalized_labels(issue.labels)
    title = normalize_text(issue.title)
    description = normalize_text(issue.description)
    text = title <> "\n" <> description

    explicit_codex? = MapSet.disjoint?(labels, MapSet.new(["codex", "needs-implementation", "submechanism"])) == false
    explicit_claude? = MapSet.disjoint?(labels, MapSet.new(["claude", "needs-architecture", "needs-review", "mechanism"])) == false
    explicit_human? = MapSet.disjoint?(labels, MapSet.new(["needs-human", "human", "credential", "credentials"])) == false
    merge_disposition? = String.starts_with?(String.downcase(title), "merge worktree output for") or String.contains?(String.downcase(text), "merge/disposition")
    architecture_signal? = explicit_claude? or merge_disposition? or String.match?(text, ~r/(architecture|review|synthesis|critique|design|merge|disposition)/i)
    implementation_signal? = explicit_codex? or String.match?(text, ~r/(implement|fix|patch|test|ci|bug|regression|code|codex)/i)
    human_signal? = explicit_human? or String.match?(text, ~r/(credential|api key|billing|quota|approval)/i)

    cond do
      human_signal? and not (explicit_codex? or explicit_claude?) ->
        route("human", ["human"], ["human_escalation"], "human-managed credential, billing, quota, or approval signal", 0.9, true)

      explicit_codex? and explicit_claude? ->
        route("dual", ["codex", "claude"], ["explicit_dual_route"], "issue carries both Codex and Claude routing labels", 0.95, false)

      explicit_claude? or (architecture_signal? and not explicit_codex?) ->
        route("claude", ["claude"], ["architecture_review_or_merge"], "architecture, synthesis, review, or merge/disposition work belongs to Claude", 0.85, false)

      true ->
        confidence = if implementation_signal?, do: 0.8, else: 0.7
        route("codex", ["codex"], ["implementation_default"], "implementation ticket defaults to the Codex worker pool", confidence, false)
    end
  end

  defp route(owner_pool, eligible_pools, route_tags, route_reason, confidence, human_escalation) do
    %{
      owner_pool: owner_pool,
      eligible_pools: eligible_pools,
      route_tags: route_tags,
      route_reason: route_reason,
      confidence: confidence,
      human_escalation: human_escalation
    }
  end

  defp issue_route_compiler do
    case System.get_env("SYMPHONY_ISSUE_ROUTE_COMPILER", "elixir")
         |> String.trim()
         |> String.downcase() do
      "dspy" -> :dspy
      "dspy-required" -> :dspy_required
      "dspy_required" -> :dspy_required
      _ -> :elixir
    end
  end

  defp compile_with_dspy(%Issue{} = issue, brief_provenance) do
    with {:ok, executable, args} <- dspy_command(),
         {:ok, input} <- dspy_input(issue, brief_provenance),
         {:ok, input_path} <- write_dspy_input(input),
         {output, 0} <- run_dspy_command(executable, args, input_path),
         {:ok, payload} <- Jason.decode(output),
         {:ok, compiled} <- normalize_dspy_compiled(payload) do
      {:ok, compiled}
    else
      {output, status} when is_integer(status) ->
        {:error, {:dspy_exit, status, String.slice(to_string(output), 0, 1_000)}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in [ErlangError, RuntimeError] ->
      {:error, {:dspy_exception, Exception.message(error)}}
  end

  defp write_dspy_input(input) when is_binary(input) do
    path = Path.join(System.tmp_dir!(), "symphony-dspy-issue-route-#{System.unique_integer([:positive])}.json")

    case File.write(path, input) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:dspy_input_write_failed, path, reason}}
    end
  end

  defp run_dspy_command(executable, args, input_path) do
    try do
      System.cmd(executable, args ++ [input_path])
    after
      File.rm(input_path)
    end
  end

  defp dspy_command do
    script = System.get_env("SYMPHONY_DSPY_ISSUE_ROUTE_SCRIPT", @dspy_script)

    if File.regular?(script) do
      case System.get_env("SYMPHONY_DSPY_ISSUE_ROUTE_RUNNER", System.get_env("SYMPHONY_DSPY_ISSUE_BRIEF_RUNNER", "uv"))
           |> String.trim()
           |> String.downcase() do
        "python" ->
          case System.find_executable("python3") || System.find_executable("python") do
            nil -> {:error, :python_not_found}
            executable -> {:ok, executable, [script]}
          end

        _ ->
          case System.find_executable("uv") do
            nil -> {:error, :uv_not_found}
            executable -> {:ok, executable, ["run", "--script", script]}
          end
      end
    else
      {:error, {:dspy_script_missing, script}}
    end
  end

  defp dspy_input(%Issue{} = issue, brief_provenance) do
    Jason.encode(%{
      "issue" => %{
        "id" => issue.id,
        "identifier" => issue.identifier,
        "title" => issue.title,
        "description" => issue.description,
        "state" => issue.state,
        "url" => issue.url,
        "labels" => issue.labels
      },
      "issue_brief" => brief_provenance || %{}
    })
  end

  defp normalize_dspy_compiled(%{
         "route" => route,
         "provenance_text" => provenance_text,
         "provenance" => provenance
       })
       when is_map(route) and is_binary(provenance_text) and is_map(provenance) do
    {:ok, %{route: normalize_route(route), provenance_text: provenance_text, provenance: provenance}}
  end

  defp normalize_dspy_compiled(payload), do: {:error, {:invalid_dspy_route_payload, payload}}

  defp normalize_route(route) when is_map(route) do
    %{
      owner_pool: safe_text(route["owner_pool"], "codex"),
      eligible_pools: route["eligible_pools"] |> list_of_strings() |> default_list(["codex"]),
      route_tags: route["route_tags"] |> list_of_strings() |> default_list(["implementation_default"]),
      route_reason: safe_text(route["route_reason"], "implementation ticket defaults to the Codex worker pool"),
      confidence: normalize_confidence(route["confidence"]),
      human_escalation: route["human_escalation"] == true
    }
  end

  defp brief_provenance(%{provenance: provenance}) when is_map(provenance), do: provenance
  defp brief_provenance(_value), do: nil

  defp maybe_put_fallback_reason(provenance, nil), do: provenance

  defp maybe_put_fallback_reason(provenance, reason) do
    Map.merge(provenance, %{
      "preferred_compiler" => "dspy",
      "compiler_fallback_reason" => inspect(reason, limit: 5)
    })
  end

  defp render_provenance(provenance) do
    [
      "signature=#{provenance["signature"]}",
      "parent_signatures=#{Enum.join(provenance["parent_signatures"], ",")}",
      "compiler=#{provenance["compiler"]}",
      "compiler_contract=#{provenance["compiler_contract"]}",
      optional_provenance_line("preferred_compiler", provenance),
      optional_provenance_line("compiler_fallback_reason", provenance),
      optional_provenance_line("dspy_version", provenance),
      "owner_pool=#{provenance["owner_pool"]}",
      "eligible_pools=#{Enum.join(provenance["eligible_pools"], ",")}",
      "route_tags=#{Enum.join(provenance["route_tags"], ",")}",
      "route_reason=#{provenance["route_reason"]}",
      "confidence=#{provenance["confidence"]}",
      "human_escalation=#{provenance["human_escalation"]}",
      "input_fields=#{Enum.join(provenance["input_fields"], ",")}",
      "output_fields=#{Enum.join(provenance["output_fields"], ",")}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp optional_provenance_line(key, provenance) do
    case Map.get(provenance, key) do
      nil -> nil
      value -> "#{key}=#{value}"
    end
  end

  defp normalized_labels(labels) when is_list(labels) do
    labels
    |> Enum.map(&normalize_text/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalized_labels(_labels), do: MapSet.new()

  defp normalize_text(nil), do: ""
  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(value), do: value |> inspect() |> String.trim()

  defp safe_text(nil, fallback), do: fallback
  defp safe_text(value, fallback) when is_binary(value), do: if(String.trim(value) == "", do: fallback, else: String.trim(value))
  defp safe_text(value, _fallback), do: inspect(value)

  defp list_of_strings(values) when is_list(values) do
    values
    |> Enum.map(&safe_text(&1, ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp list_of_strings(_values), do: []

  defp default_list([], fallback), do: fallback
  defp default_list(values, _fallback), do: values

  defp normalize_confidence(value) when is_float(value), do: value
  defp normalize_confidence(value) when is_integer(value), do: value / 1
  defp normalize_confidence(_value), do: 0.7
end
