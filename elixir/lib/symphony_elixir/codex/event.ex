defmodule SymphonyElixir.Codex.Event do
  @moduledoc """
  Normalizes Codex app-server event payloads into canonical fields.

  The app-server, orchestrator, and dashboard all depend on the same live Codex
  stream. Keep payload-shape knowledge here so guard enforcement and
  observability cannot drift apart.
  """

  @token_usage_paths [
    ["params", "msg", "payload", "info", "total_token_usage"],
    [:params, :msg, :payload, :info, :total_token_usage],
    ["params", "msg", "info", "total_token_usage"],
    [:params, :msg, :info, :total_token_usage],
    ["params", "tokenUsage", "total"],
    [:params, :tokenUsage, :total],
    ["tokenUsage", "total"],
    [:tokenUsage, :total],
    ["params", "usage"],
    [:params, :usage],
    ["params", "tokenUsage"],
    [:params, :tokenUsage],
    ["usage"],
    [:usage],
    ["tokenUsage"],
    [:tokenUsage]
  ]

  @command_output_delta_methods [
    "item/commandExecution/outputDelta",
    "item/fileChange/outputDelta",
    "codex/event/exec_command_output_delta"
  ]

  @command_output_delta_paths [
    ["params", "delta"],
    ["params", "outputDelta"],
    ["params", "msg", "delta"],
    ["params", "msg", "outputDelta"],
    ["params", "msg", "payload", "delta"],
    ["params", "msg", "payload", "outputDelta"],
    [:params, :delta],
    [:params, :outputDelta],
    [:params, :msg, :delta],
    [:params, :msg, :outputDelta],
    [:params, :msg, :payload, :delta],
    [:params, :msg, :payload, :outputDelta]
  ]

  @command_event_methods [
    "codex/event/exec_command_begin",
    "item/commandExecution/requestApproval",
    "execCommandApproval"
  ]

  @command_paths [
    ["params", "msg", "command"],
    [:params, :msg, :command],
    ["params", "msg", "parsed_cmd"],
    [:params, :msg, :parsed_cmd],
    ["params", "msg", "parsedCmd"],
    [:params, :msg, :parsedCmd],
    ["params", "command"],
    [:params, :command],
    ["params", "cmd"],
    [:params, :cmd],
    ["params", "parsedCmd"],
    [:params, :parsedCmd],
    ["params", "argv"],
    [:params, :argv],
    ["params", "args"],
    [:params, :args]
  ]

  @spec token_usage(map()) :: map() | nil
  def token_usage(payload) when is_map(payload) do
    Enum.find_value(@token_usage_paths, fn path ->
      payload
      |> value_at_path(path)
      |> usage_from_value()
    end)
  end

  def token_usage(_payload), do: nil

  @spec token_usage_from_update(map()) :: map()
  def token_usage_from_update(update) when is_map(update) do
    payload = update[:payload] || Map.get(update, "payload") || Map.get(update, :payload)

    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      payload,
      wrapped_payload(payload),
      update
    ]

    Enum.find_value(payloads, &token_usage/1) || %{}
  end

  def token_usage_from_update(_update), do: %{}

  @spec reported_token_total(map()) :: non_neg_integer() | nil
  def reported_token_total(payload) when is_map(payload) do
    payload
    |> token_usage()
    |> total_tokens()
  end

  def reported_token_total(_payload), do: nil

  @spec input_tokens(map()) :: non_neg_integer() | nil
  def input_tokens(usage), do: payload_get(usage, ["input_tokens", "prompt_tokens", :input_tokens, :prompt_tokens, :input, "promptTokens", :promptTokens, "inputTokens", :inputTokens])

  @spec output_tokens(map()) :: non_neg_integer() | nil
  def output_tokens(usage),
    do: payload_get(usage, ["output_tokens", "completion_tokens", :output_tokens, :completion_tokens, :output, :completion, "outputTokens", :outputTokens, "completionTokens", :completionTokens])

  @spec total_tokens(map()) :: non_neg_integer() | nil
  def total_tokens(usage), do: payload_get(usage, ["total_tokens", "total", :total_tokens, :total, "totalTokens", :totalTokens])

  @spec command_output_delta(map()) :: binary() | nil
  def command_output_delta(payload) when is_map(payload) do
    method = method(payload)

    if method in @command_output_delta_methods do
      Enum.find_value(@command_output_delta_paths, &binary_at_path(payload, &1))
    end
  end

  def command_output_delta(_payload), do: nil

  @spec command_event?(map()) :: boolean()
  def command_event?(payload) when is_map(payload), do: method(payload) in @command_event_methods
  def command_event?(_payload), do: false

  @spec method(map()) :: String.t() | nil
  def method(payload) when is_map(payload) do
    case Map.get(payload, "method") || Map.get(payload, :method) do
      method when is_binary(method) -> method
      _ -> payload |> wrapped_payload() |> method_from_wrapped()
    end
  end

  def method(_payload), do: nil

  @spec command(map()) :: String.t() | nil
  def command(payload) when is_map(payload) do
    Enum.find_value(@command_paths, fn path ->
      payload
      |> value_at_path(path)
      |> normalize_command()
    end)
  end

  def command(_payload), do: nil

  defp usage_from_value(value) when is_map(value) do
    if integer_token_map?(value), do: value
  end

  defp usage_from_value(value) do
    case integer_like(value) do
      total when is_integer(total) -> %{"total_tokens" => total}
      nil -> nil
    end
  end

  defp integer_token_map?(payload) when is_map(payload) do
    [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]
    |> Enum.any?(fn field -> !is_nil(payload_get(payload, field)) end)
  end

  defp integer_token_map?(_payload), do: false

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> payload_get(payload, field) end)
  end

  defp payload_get(payload, field) when is_map(payload) do
    payload
    |> Map.get(field)
    |> integer_like()
  end

  defp payload_get(_payload, _field), do: nil

  defp binary_at_path(payload, path) do
    case value_at_path(payload, path) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp wrapped_payload(%{"payload" => payload}) when is_map(payload), do: payload
  defp wrapped_payload(%{payload: payload}) when is_map(payload), do: payload
  defp wrapped_payload(_payload), do: nil

  defp method_from_wrapped(payload) when is_map(payload), do: method(payload)
  defp method_from_wrapped(_payload), do: nil

  defp normalize_command(%{} = command) do
    binary_command = Map.get(command, "parsedCmd") || Map.get(command, :parsedCmd) || Map.get(command, "command") || Map.get(command, :command) || Map.get(command, "cmd") || Map.get(command, :cmd)
    args = Map.get(command, "args") || Map.get(command, :args) || Map.get(command, "argv") || Map.get(command, :argv)

    if is_binary(binary_command) and is_list(args) do
      normalize_command([binary_command | args])
    else
      normalize_command(binary_command || args)
    end
  end

  defp normalize_command(command) when is_binary(command) do
    command
    |> String.replace("\n", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(160)
    |> empty_to_nil()
  end

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command
      |> Enum.join(" ")
      |> normalize_command()
    end
  end

  defp normalize_command(_command), do: nil

  defp value_at_path(payload, path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      cond do
        is_map(acc) and Map.has_key?(acc, key) ->
          {:cont, Map.get(acc, key)}

        is_map(acc) and is_atom(key) and Map.has_key?(acc, Atom.to_string(key)) ->
          {:cont, Map.get(acc, Atom.to_string(key))}

        true ->
          {:halt, nil}
      end
    end)
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp truncate(text, max_bytes) when byte_size(text) <= max_bytes, do: text
  defp truncate(text, max_bytes), do: binary_part(text, 0, max_bytes) <> "..."

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value
end
