import * as builder from "annotatedtext-remark";
import fs from "fs";
import process from "process";

function readFileContent(filename) {
  return fs.readFileSync(filename, "utf-8");
}

const filename = process.argv[2];
const text = readFileContent(filename);

const annotatedText = builder.build(text);
console.log(JSON.stringify(annotatedText));
