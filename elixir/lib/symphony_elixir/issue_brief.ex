defmodule SymphonyElixir.IssueBrief do
  @moduledoc """
  Compiles raw tracker issues into a bounded, provenance-bearing prompt context.

  The shape mirrors a DSPy signature: tracker fields are treated as typed inputs
  and the prompt consumes named outputs instead of an unbounded issue body.
  """

  alias SymphonyElixir.Linear.Issue

  @signature_version "SymphonyIssueBriefV1"
  @default_max_description_chars 6_000
  @max_signal_lines 12
  @max_acceptance_lines 8
  @max_line_chars 240

  @input_fields ["identifier", "title", "state", "labels", "url", "description"]
  @output_fields [
    "objective",
    "requirements",
    "acceptance_criteria",
    "evidence_pointers",
    "description_excerpt"
  ]
  @dspy_script Path.expand("../../../../scripts/symphony-dspy-issue-brief.py", __DIR__)

  @type compiled :: %{
          brief: String.t(),
          provenance_text: String.t(),
          provenance: map()
        }

  @spec default_max_description_chars() :: non_neg_integer()
  def default_max_description_chars, do: @default_max_description_chars

  @spec compile(Issue.t(), keyword()) :: compiled()
  def compile(%Issue{} = issue, opts \\ []) do
    max_chars =
      opts
      |> Keyword.get(:max_description_chars, @default_max_description_chars)
      |> normalize_max_chars()

    case issue_brief_compiler() do
      :dspy ->
        case compile_with_dspy(issue, max_chars) do
          {:ok, compiled} -> compiled
          {:error, reason} -> compile_elixir(issue, max_chars, reason)
        end

      :dspy_required ->
        case compile_with_dspy(issue, max_chars) do
          {:ok, compiled} -> compiled
          {:error, reason} -> raise RuntimeError, "dspy_issue_brief_failed: #{inspect(reason)}"
        end

      :elixir ->
        compile_elixir(issue, max_chars)
    end
  end

  defp compile_elixir(%Issue{} = issue, max_chars, fallback_reason \\ nil) do
    raw_description = normalize_text(issue.description)
    description_excerpt = bounded_excerpt(raw_description, max_chars)
    description_truncated = String.length(raw_description) > String.length(description_excerpt)

    requirements = extract_signal_lines(description_excerpt, @max_signal_lines)
    acceptance_criteria = extract_acceptance_lines(description_excerpt, @max_acceptance_lines)

    provenance =
      %{
        "signature" => @signature_version,
        "compiler" => "symphony_elixir.issue_brief",
        "compiler_contract" => "dspy-compatible-signature",
        "input_fields" => @input_fields,
        "output_fields" => @output_fields,
        "description_sha256" => sha256(raw_description),
        "description_chars" => String.length(raw_description),
        "description_bytes" => byte_size(raw_description),
        "description_included_chars" => String.length(description_excerpt),
        "description_included_bytes" => byte_size(description_excerpt),
        "description_truncated" => description_truncated,
        "max_issue_description_chars" => max_chars
      }
      |> maybe_put_fallback_reason(fallback_reason)

    %{
      brief: render_brief(issue, requirements, acceptance_criteria, description_excerpt, provenance),
      provenance_text: render_provenance(provenance),
      provenance: provenance
    }
  end

  defp issue_brief_compiler do
    case System.get_env("SYMPHONY_ISSUE_BRIEF_COMPILER", "elixir") |> String.trim() |> String.downcase() do
      "dspy" -> :dspy
      "dspy-required" -> :dspy_required
      "dspy_required" -> :dspy_required
      _ -> :elixir
    end
  end

  defp compile_with_dspy(%Issue{} = issue, max_chars) do
    with {:ok, executable, args} <- dspy_command(),
         {:ok, input} <- dspy_input(issue, max_chars),
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
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-dspy-issue-brief-#{System.unique_integer([:positive])}.json"
      )

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
    script = System.get_env("SYMPHONY_DSPY_ISSUE_BRIEF_SCRIPT", @dspy_script)

    if File.regular?(script) do
      case System.get_env("SYMPHONY_DSPY_ISSUE_BRIEF_RUNNER", "uv") |> String.trim() |> String.downcase() do
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

  defp dspy_input(%Issue{} = issue, max_chars) do
    Jason.encode(%{
      "max_description_chars" => max_chars,
      "issue" => %{
        "id" => issue.id,
        "identifier" => issue.identifier,
        "title" => issue.title,
        "description" => issue.description,
        "state" => issue.state,
        "url" => issue.url,
        "labels" => issue.labels
      }
    })
  end

  defp normalize_dspy_compiled(%{
         "brief" => brief,
         "provenance_text" => provenance_text,
         "provenance" => provenance
       })
       when is_binary(brief) and is_binary(provenance_text) and is_map(provenance) do
    {:ok, %{brief: brief, provenance_text: provenance_text, provenance: provenance}}
  end

  defp normalize_dspy_compiled(payload), do: {:error, {:invalid_dspy_payload, payload}}

  defp maybe_put_fallback_reason(provenance, nil), do: provenance

  defp maybe_put_fallback_reason(provenance, reason) do
    Map.merge(provenance, %{
      "preferred_compiler" => "dspy",
      "compiler_fallback_reason" => inspect(reason, limit: 5)
    })
  end

  defp normalize_max_chars(value) when is_integer(value) and value >= 0, do: value
  defp normalize_max_chars(_value), do: @default_max_description_chars

  defp normalize_text(nil), do: ""

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.trim()
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()

  defp bounded_excerpt(_description, 0), do: ""

  defp bounded_excerpt(description, max_chars) do
    if String.length(description) <= max_chars do
      description
    else
      description
      |> String.slice(0, max_chars)
      |> String.trim_trailing()
    end
  end

  defp extract_signal_lines(description, limit) do
    description
    |> normalized_lines()
    |> Enum.filter(&signal_line?/1)
    |> compact_lines(limit)
    |> default_list(["No concise requirements were extracted from the issue body."])
  end

  defp extract_acceptance_lines(description, limit) do
    description
    |> normalized_lines()
    |> Enum.filter(&acceptance_line?/1)
    |> compact_lines(limit)
    |> default_list(["Leave validation evidence and an explicit outcome file before stopping."])
  end

  defp normalized_lines(description) do
    description
    |> String.split("\n", trim: true)
    |> Enum.map(&normalize_line/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_line(line) do
    line
    |> String.trim()
    |> String.trim_leading("-")
    |> String.trim_leading("*")
    |> String.trim_leading("#")
    |> String.trim()
  end

  defp signal_line?(line) do
    String.match?(
      line,
      ~r/(must|should|required|before|after|verify|test|cache|dataset|searchr1|deepsearch|aime|provenance|sync|launch|block|guard|path|linear|github|issue|priority|acceptance|done)/i
    )
  end

  defp acceptance_line?(line) do
    String.match?(
      line,
      ~r/(acceptance|verify|test|passes|done|complete|evidence|validation|cache|manifest|provenance|github|linear)/i
    )
  end

  defp compact_lines(lines, limit) do
    lines
    |> Enum.uniq()
    |> Enum.take(limit)
    |> Enum.map(&String.slice(&1, 0, @max_line_chars))
  end

  defp default_list([], fallback), do: fallback
  defp default_list(lines, _fallback), do: lines

  defp render_brief(issue, requirements, acceptance_criteria, description_excerpt, provenance) do
    [
      "Signature: #{@signature_version} (DSPy-compatible issue brief)",
      "",
      "Objective:",
      "- #{safe_text(issue.title, "Untitled issue")}",
      "",
      "Control-plane context:",
      "- Identifier: #{safe_text(issue.identifier, "unknown")}",
      "- State: #{safe_text(issue.state, "unknown")}",
      "- Labels: #{format_labels(issue.labels)}",
      "- URL: #{safe_text(issue.url, "not provided")}",
      "",
      "Structured requirements:",
      render_list(requirements),
      "",
      "Acceptance criteria:",
      render_list(acceptance_criteria),
      "",
      "Description excerpt:",
      description_excerpt_text(description_excerpt),
      "",
      "Context budget:",
      "- description_sha256: #{provenance["description_sha256"]}",
      "- included_chars: #{provenance["description_included_chars"]}/#{provenance["description_chars"]}",
      "- truncated: #{provenance["description_truncated"]}"
    ]
    |> Enum.join("\n")
  end

  defp render_list(lines) do
    lines
    |> Enum.map(&"- #{&1}")
    |> Enum.join("\n")
  end

  defp description_excerpt_text(""), do: "No description provided."
  defp description_excerpt_text(excerpt), do: excerpt

  defp render_provenance(provenance) do
    [
      "signature=#{provenance["signature"]}",
      "compiler=#{provenance["compiler"]}",
      "compiler_contract=#{provenance["compiler_contract"]}",
      optional_provenance_line("preferred_compiler", provenance),
      optional_provenance_line("compiler_fallback_reason", provenance),
      optional_provenance_line("dspy_version", provenance),
      "input_fields=#{Enum.join(provenance["input_fields"], ",")}",
      "output_fields=#{Enum.join(provenance["output_fields"], ",")}",
      "description_sha256=#{provenance["description_sha256"]}",
      "description_chars=#{provenance["description_chars"]}",
      "description_bytes=#{provenance["description_bytes"]}",
      "description_included_chars=#{provenance["description_included_chars"]}",
      "description_included_bytes=#{provenance["description_included_bytes"]}",
      "description_truncated=#{provenance["description_truncated"]}",
      "max_issue_description_chars=#{provenance["max_issue_description_chars"]}"
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

  defp safe_text(nil, fallback), do: fallback

  defp safe_text(value, fallback) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: fallback, else: value
  end

  defp safe_text(value, _fallback), do: inspect(value)

  defp format_labels(labels) when is_list(labels) and labels != [] do
    labels
    |> Enum.map(&safe_text(&1, ""))
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> "none"
      values -> Enum.join(values, ", ")
    end
  end

  defp format_labels(_labels), do: "none"

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
