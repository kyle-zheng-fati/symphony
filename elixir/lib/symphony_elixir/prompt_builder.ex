defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, IssueBrief, IssueRoute, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    workflow = Workflow.current()

    template =
      workflow
      |> prompt_template!()
      |> parse_template!()

    settings = Config.settings!()
    compiled_issue = IssueBrief.compile(issue, max_description_chars: settings.agent.max_issue_description_chars)
    compiled_route = IssueRoute.compile(issue, compiled_issue: compiled_issue)
    context_provenance = Enum.join([compiled_issue.provenance_text, compiled_route.provenance_text], "\n")

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" =>
          issue
          |> Map.from_struct()
          |> Map.merge(%{
            brief: compiled_issue.brief,
            route: compiled_route.route,
            route_summary: render_route_summary(compiled_route.route),
            context_provenance: context_provenance,
            route_provenance: compiled_route.provenance_text,
            prompt_provenance: compiled_issue.provenance
          })
          |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp render_route_summary(%{owner_pool: owner_pool, eligible_pools: eligible_pools, route_reason: route_reason}) do
    [
      "- owner_pool: #{owner_pool}",
      "- eligible_pools: #{Enum.join(eligible_pools, ",")}",
      "- reason: #{route_reason}"
    ]
    |> Enum.join("\n")
  end

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
