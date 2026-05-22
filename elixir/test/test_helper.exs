defmodule SymphonyElixir.TestDotenv do
  def load(path) when is_binary(path) do
    if File.regular?(path) do
      path
      |> File.stream!([], :line)
      |> Enum.each(&put_line/1)
    end
  end

  defp put_line(raw) do
    line =
      raw
      |> String.trim()
      |> String.trim_leading("export ")

    cond do
      line == "" or String.starts_with?(line, "#") or not String.contains?(line, "=") ->
        :ok

      true ->
        [key, value] = String.split(line, "=", parts: 2)
        key = String.trim(key)

        if key != "" and is_nil(System.get_env(key)) do
          System.put_env(key, value |> String.trim() |> String.trim("'\""))
        end
    end
  end
end

SymphonyElixir.TestDotenv.load(Path.expand("~/.env"))
SymphonyElixir.TestDotenv.load(Path.expand("../../.env", __DIR__))

ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
