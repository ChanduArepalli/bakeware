defmodule Bakeware.Assembler do
  @moduledoc false
  defstruct [:compress?, :cpio, :launcher, :name, :output, :path, :release, :rel_path, :trailer]

  @doc false
  def assemble(%Mix.Release{} = release) do
    %__MODULE__{name: release.name, rel_path: release.path, release: release}
    |> do_assemble()
    # Assembler requires %Mix.Release{} struct returned
    |> Map.get(:release)
  end

  @doc false
  def assemble(path, name) do
    %__MODULE__{name: name, rel_path: Path.expand(path)}
    |> do_assemble()
  end

  defp create_paths(assembler) do
    bake_path = Path.dirname(assembler.rel_path) |> Path.join("bakeware")
    tmp_name = :crypto.strong_rand_bytes(16) |> Base.encode16()

    _ = File.mkdir_p!(bake_path)

    %{
      assembler
      | path: bake_path,
        cpio: Path.join(bake_path, "#{tmp_name}.cpio"),
        launcher: Path.join(:code.priv_dir(:bakeware), "launcher"),
        output: Path.join(bake_path, "#{assembler.name}"),
        trailer: Path.join(bake_path, "#{tmp_name}.trailer")
    }
  end

  defp do_assemble(assembler) do
    IO.puts("""
    #{IO.ANSI.green()}* assembling#{IO.ANSI.default_color()} bakeware #{assembler.name}
    """)

    assembler
    |> create_paths()
    |> set_compression()
    |> add_start_script()
    |> build_cpio()
    |> build_trailer()
    |> concat_files()
    |> cleanup_files()
  end

  defp add_start_script(assembler) do
    start_path = Path.join(assembler.rel_path, "start")
    start_script_path = "bin/#{assembler.name}"

    script = """
    #!/bin/sh
    SELF=$(readlink "$0" || true)
    if [ -z "$SELF" ]; then SELF="$0"; fi
    ROOT="$(cd "$(dirname "$SELF")" && pwd -P)"

    $ROOT/#{start_script_path} start
    """

    File.write!(start_path, script)
    File.chmod!(start_path, 0o755)

    assembler
  end

  defp build_cpio(assembler) do
    maybe_zstd = if assembler.compress?, do: '| zstd -15 -'

    _ =
      :os.cmd(
        'cd #{assembler.rel_path} && find . | cpio -o -H newc -v #{maybe_zstd} > #{assembler.cpio}'
      )

    assembler
  end

  defp build_trailer(assembler) do
    # maybe stream here to be more efficient
    hash = :crypto.hash(:sha256, File.read!(assembler.cpio))
    offset = File.stat!(assembler.launcher).size
    cpio_size = File.stat!(assembler.cpio).size

    compression = if assembler.compress?, do: 1, else: 0
    trailer_version = 1
    flags = 0

    trailer_bin =
      <<hash::binary, cpio_size::32, offset::32, flags::16, compression::8, trailer_version::8,
        "BAKE">>

    File.write!(assembler.trailer, trailer_bin)
    assembler
  end

  defp cleanup_files(assembler) do
    _ = File.rm_rf!(assembler.cpio)
    _ = File.rm_rf!(assembler.trailer)

    IO.puts("Bakeware successfully assembled executable at:\n")
    IO.puts("    #{Path.relative_to(assembler.output, File.cwd!())}")

    assembler
  end

  defp concat_files(assembler) do
    _ =
      :os.cmd(
        'cat #{assembler.launcher} #{assembler.cpio} #{assembler.trailer} > #{assembler.output}'
      )

    File.chmod!(assembler.output, 0o755)
    assembler
  end

  defp set_compression(assembler) do
    compress? =
      case System.find_executable("zstd") do
        nil ->
          # no compression
          IO.puts("""
          #{IO.ANSI.yellow()}* warning#{IO.ANSI.default_color()} [Bakeware] zstd not installed. Skipping compression...
          """)

          false

        _path ->
          true
      end

    %{assembler | compress?: compress?}
  end
end
