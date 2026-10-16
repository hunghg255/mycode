import { generateManifest } from "./src/core";
import { writeFileSync, readFileSync, mkdirSync, rmSync, existsSync } from "node:fs";
const out = process.env.OUT!;
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
const m: any = generateManifest();
const color = "#90a4ae";
const svg = (body: string) => `<svg viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg">${body}</svg>`;
const p = (d: string) => `<path d="${d}" fill="${color}" />`;
const generated: Record<string, string> = {
  file: svg(p("m8.668 6h3.6641l-3.6641-3.668v3.668m-4.668-4.668h5.332l4 4v8c0 0.73828-0.59375 1.3359-1.332 1.3359h-8c-0.73828 0-1.332-0.59766-1.332-1.3359v-10.664c0-0.74219 0.59375-1.3359 1.332-1.3359m3.332 1.3359h-3.332v10.664h8v-6h-4.668z")),
  folder: svg(p("m6.922 3.768-.644-.536A1 1 0 0 0 5.638 3H2a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V5a1 1 0 0 0-1-1H7.562a1 1 0 0 1-.64-.232")),
  "folder-open": svg(p("M14.483 6H4.721a1 1 0 0 0-.949.684L2 12V5h12a1 1 0 0 0-1-1H7.562a1 1 0 0 1-.64-.232l-.644-.536A1 1 0 0 0 5.638 3H2a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h11l2.403-5.606A1 1 0 0 0 14.483 6")),
};
const used = new Set<string>([m.file, m.folder, m.folderExpanded]);
const pick = (o: any) => { const r: any = {}; for (const [k, v] of Object.entries(o ?? {})) { r[k.toLowerCase()] = v; used.add(v as string); } return r; };
const data: any = {
  file: m.file, folder: m.folder, folderExpanded: m.folderExpanded,
  fileExtensions: pick(m.fileExtensions), fileNames: pick(m.fileNames),
  folderNames: pick(m.folderNames), folderNamesExpanded: pick(m.folderNamesExpanded),
  light: {
    fileExtensions: pick(m.light.fileExtensions), fileNames: pick(m.light.fileNames),
    folderNames: pick(m.light.folderNames), folderNamesExpanded: pick(m.light.folderNamesExpanded),
  },
};
writeFileSync(`${out}/manifest.json`, JSON.stringify(data));
let n = 0, miss: string[] = [];
for (const name of used) {
  let body = generated[name];
  if (!body) {
    const def = m.iconDefinitions[name];
    const f = def?.iconPath.replace("./../", "./");
    if (!f || !existsSync(f)) { miss.push(name); continue; }
    body = readFileSync(f, "utf8");
  }
  writeFileSync(`${out}/${name}.svg`, body); n++;
}
writeFileSync(`${out}/LICENSE`, readFileSync("LICENSE", "utf8"));
console.log("svgs", n, "missing", miss);
console.log("slashes in folderNames", Object.keys(data.folderNames).filter(k => k.includes("/")).length);
