import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const [monorepo, executable, ...nativeArgs] = process.argv.slice(2);
assert(monorepo && executable, "Pass the built monorepo directory, native executable and any launcher arguments");
const cli = path.resolve(monorepo, "packages/cli/bin.js");
assert(fs.existsSync(cli), "Expected the local Node CLI");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "featurevisor runtime "));
let checks = 0;
const failures = [];
function write(file, content) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
}
function project(name, environments, sets) {
  const root = path.join(temp, name);
  write(path.join(root, "featurevisor.config.js"), `module.exports = ${JSON.stringify({
    ...(environments ? { environments: ["production"] } : {}),
    ...(sets ? { sets: true, setsDirectoryPath: path.join(root, "lanes with spaces") } : {}),
  })};\n`);
  for (const set of sets ? ["store front", "admin"] : [""]) {
    const directory = set ? path.join(root, "lanes with spaces", set) : root;
    const rules = '- key: everyone\n  conditions: "*"\n  percentage: 100\n';
    write(path.join(directory, "features/checkout.yml"),
      "description: Checkout\nbucketBy: userId\nrules:\n" +
      (environments ? "  production:\n" + rules.split("\n").filter(Boolean).map(line => "    " + line).join("\n") + "\n"
        : rules.split("\n").filter(Boolean).map(line => "  " + line).join("\n") + "\n"));
    write(path.join(directory, "variables/colour.yml"),
      `description: Colour\ntype: string\ndefaultValue: ${set === "admin" ? "red" : "blue"}\n`);
    write(path.join(directory, "targets/all.yml"), "description: All definitions\n");
    write(path.join(directory, "targets/nested/web.yml"), "description: Nested target\nincludeFeatures:\n  - checkout\nincludeVariables:\n  - colour\n");
    write(path.join(directory, "targets/selected web.yml"), "description: Selected checkout\nincludeFeatures:\n  - checkout\nincludeVariables:\n  - colour\n");
  }
  return root;
}
function snapshot(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name)).flatMap(entry => {
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? snapshot(file) : [[file, fs.readFileSync(file, "utf8")]];
  });
}
function run(label, root, command, options, expected, pattern) {
  const args = [...nativeArgs, command, "--projectDirectoryPath=" + root, "--n=2", ...options];
  const result = spawnSync(executable, args, {
    encoding: "utf8", timeout: 60000,
    env: { ...process.env, PATH: path.join(temp, "bin") + path.delimiter + process.env.PATH },
  });
  const output = result.stdout + result.stderr;
  try {
    assert.equal(result.error, undefined);
    assert.equal(result.signal, null);
    assert.equal(result.status === 0, expected === 0, output);
    if (pattern) assert.match(output, pattern);
    checks++;
  } catch (error) { failures.push(label + ": " + error.message); }
}
try {
  // Only delegation is redirected. This executes the real local Node CLI without npx downloads.
  write(path.join(temp, "bin/npx"), `#!/usr/bin/env node\nif (process.argv[2] !== "featurevisor") process.exit(97);\nprocess.argv = [process.execPath, ${JSON.stringify(cli)}, ...process.argv.slice(3)];\nrequire(${JSON.stringify(cli)});\n`);
  fs.chmodSync(path.join(temp, "bin/npx"), 0o755);
  const flat = project("flat", false, false);
  const configured = project("configured", true, false);
  const sets = project("sets", false, true);
  const configuredSets = project("configured sets", true, true);
  const emptySets = project("empty sets", false, true);
  fs.rmSync(path.join(emptySets, "lanes with spaces"), { recursive: true });
  write(path.join(emptySets, "lanes with spaces/ignored.txt"), "not a set");
  const before = snapshot(temp);
  for (const command of ["benchmark", "assess-distribution"]) {
    const options = ["--feature=checkout"];
    run(command + " inflate one", flat, command, [...options, "--inflate=1"], 0);
    for (const value of ["0", "-1", "1.5", "invalid"]) {
      run(command + " invalid inflate " + value, flat, command, [...options, "--inflate=" + value], 1);
    }
    run(command + " flat", flat, command, options, 0, command === "benchmark" ? /Evaluated value\s*:\s*true/ : /(?:enabled|true): 2/);
    run(command + " relative flat path with spaces", path.relative(process.cwd(), flat), command, options, 0);
    run(command + " relative set path with spaces", path.relative(process.cwd(), sets), command,
      [...options, "--set=store front", "--target=selected web"], 0);
    run(command + " configured", configured, command, [...options, "--environment=production"], 0);
    run(command + " missing environment", configured, command, options, 1);
    run(command + " invalid environment", configured, command, [...options, "--environment=unknown"], 1);
    run(command + " unexpected environment", flat, command, [...options, "--environment=production"], 1);
    for (const [root, env] of [[sets, []], [configuredSets, ["--environment=production"]]]) {
      run(command + " selected set", root, command, [...options, ...env, "--set=store front", "--target=selected web"], 0);
      run(command + " all sets", root, command, [...options, ...env], 0, /Set: admin[\s\S]*Set: store front/);
      run(command + " all sets with nested targets", root, command,
        [...options, ...env, "--target=nested.web", "--target=selected web", "--target=nested.web"], 0,
        /Set: admin[\s\S]*Target: nested\.web[\s\S]*Target: selected web[\s\S]*Set: store front[\s\S]*Target: nested\.web[\s\S]*Target: selected web/);
      run(command + " selected set with nested targets", root, command,
        [...options, ...env, "--set=store front", "--target=nested.web", "--target=selected web"], 0,
        /Set: store front[\s\S]*Target: nested\.web[\s\S]*Target: selected web/);
      run(command + " unknown set", root, command, [...options, ...env, "--set=unknown"], 1);
    }
    run(command + " targets", flat, command, [...options, "--target=all", "--target=selected web", "--target=all"], 0, /Target: selected web/);
    run(command + " unknown target", flat, command, [...options, "--target=all", "--target=unknown"], 1);
    run(command + " empty sets", emptySets, command, options, 1);
    run(command + " all sets missing environment", configuredSets, command, options, 1);
    run(command + " all sets invalid environment", configuredSets, command, [...options, "--environment=unknown"], 1);
    run(command + " all sets unknown target", sets, command, [...options, "--target=unknown"], 1);
  }
  run("global variable flat", flat, "benchmark", ["--variable=colour"], 0, /Evaluated value\s*:\s*"?blue/);
  run("global variable selected set", sets, "benchmark", ["--variable=colour", "--set=admin"], 0, /Evaluated value\s*:\s*"?red/);
  run("global variable all sets", sets, "benchmark", ["--variable=colour"], 0,
    /Set: admin[\s\S]*Evaluated value\s*:\s*"?red[\s\S]*Set: store front[\s\S]*Evaluated value\s*:\s*"?blue/);
  assert.deepEqual(snapshot(temp), before, "Runtime commands must not write datafiles or allocation state");
  console.log(`${checks} runtime integration checks passed; ${failures.length} failed. Project files unchanged.`);
  for (const failure of failures) console.error(failure);
  if (failures.length) process.exitCode = 1;
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
