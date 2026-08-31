// Self-contained regression for the bounded iOS API, not a desktop renderer.
import fs from "node:fs/promises";
import { Presentation, PresentationFile, FileBlob } from "@oai/artifact-tool";
await fs.mkdir("output", { recursive: true });
const deck = Presentation.create({ slideSize: { width: 1280, height: 720 } });
const slide = deck.slides.add();
const shape = slide.shapes.add({
  name: "title", position: { left: 48, top: 48, width: 720, height: 96 },
  fill: "rgb(239,246,255)", line: { fill: "rgb(37,99,235)", width: 2 }
});
shape.text = "iOS presentation round trip";
shape.text.fontSize = 28;
const preview = await deck.export({ slide, format: "png", scale: 0.5, previewMode: "schematic" });
await preview.save("output/slide.png");
const layout = await deck.export({ slide, format: "layout" });
await fs.writeFile("output/slide.layout.json", await layout.text());
const pptx = await PresentationFile.exportPptx(deck);
await pptx.save("output/deck.pptx");
const imported = await PresentationFile.importPptx(await FileBlob.load("output/deck.pptx"));
if (imported.slides.count !== 1) throw new Error("Lost slide during PPTX round trip");
const restored = JSON.parse(await (await imported.export({ slide: imported.slides.getItem(0), format: "layout" })).text());
if (!restored.elements.some(element => String(element.text || "").includes("iOS presentation round trip"))) {
  throw new Error("Lost text during PPTX round trip");
}
const bytes = new Uint8Array(await preview.arrayBuffer());
if (bytes.length < 100 || bytes[0] !== 137 || bytes[1] !== 80) throw new Error("Invalid PNG preview");
console.log("ok");
