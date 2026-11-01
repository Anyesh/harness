export async function tempDirFoldsCase(): Promise<boolean> {
  const dir = await Deno.makeTempDir();
  try {
    await Deno.writeTextFile(`${dir}/a`, "");
    return await Deno.stat(`${dir}/A`).then(() => true, () => false);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
}
