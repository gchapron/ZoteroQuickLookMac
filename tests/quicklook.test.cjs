const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

function deferred() {
	let resolve, reject;
	const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
	return { promise, resolve, reject };
}

function childProcess() {
	const exit = deferred();
	return {
		killed: 0,
		stdout: { readString: async () => "" },
		wait: () => exit.promise,
		kill() { this.killed++; },
		finish(exitCode = 0) { exit.resolve({ exitCode }); },
	};
}

function harness() {
	const h = {
		files: new Map(),
		items: new Map(),
		exports: [],
		launches: [],
		processes: [],
		removed: [],
		alerts: [],
		downloads: [],
	};
	const Zotero = {
		debug() {},
		getMainWindow: () => null,
		getTempDirectory: () => ({ path: "/tmp/zotero-tests" }),
		Items: { get: (id) => h.items.get(id) },
		Attachments: { LINK_MODE_LINKED_URL: 3 },
		PDFWorker: {
			async export(...args) {
				h.exports.push(args);
				if (h.exportHandler) return h.exportHandler(...args);
				h.files.set(args[1], "PDF with exported Zotero annotations");
			},
		},
		Sync: {
			Storage: { Local: { getEnabledForLibrary: () => true } },
			Runner: {
				async downloadFile(item) {
					h.downloads.push(item.id);
					if (h.downloadHandler) await h.downloadHandler(item);
				},
			},
		},
	};
	const context = vm.createContext({
		Zotero,
		PathUtils: {
			join: path.posix.join,
			filename: path.posix.basename,
			parent: path.posix.dirname,
		},
		IOUtils: {
			exists: async (name) => h.files.has(name),
			makeDirectory: async () => {},
			write: async (name, data) => { h.files.set(name, data); },
			writeUTF8: async (name, data) => { h.files.set(name, data); },
			setPermissions: async () => {},
			async remove(name) {
				h.removed.push(name);
				for (const file of h.files.keys()) {
					if (file === name || file.startsWith(name + "/")) h.files.delete(file);
				}
			},
		},
		Services: { prompt: { alert: (...args) => h.alerts.push(args) } },
		ChromeUtils: {
			importESModule: () => ({
				Subprocess: {
					async call(options) {
						h.launches.push(options);
						const proc = childProcess();
						h.processes.push(proc);
						if (h.launchHandler) await h.launchHandler(options, proc);
						return proc;
					},
				},
			}),
		},
	});
	vm.runInContext(fs.readFileSync(path.join(__dirname, "..", "quicklook.js"), "utf8"), context);
	h.preview = context.QuickLook;
	h.preview._ensureBundledBinary = async (name) => "/bundle/" + name;
	h.attachment = (id, filename, annotations = []) => {
		const item = {
			id,
			key: "KEY" + id,
			libraryID: 1,
			attachmentLinkMode: 0,
			isAttachment: () => true,
			isNote: () => false,
			isImportedAttachment: () => true,
			getFilePathAsync: async () => filename,
			getAnnotations: () => annotations,
		};
		h.items.set(id, item);
		h.files.set(filename, "original PDF bytes");
		return item;
	};
	h.parent = (id, children) => {
		const item = {
			id,
			isAttachment: () => false,
			isNote: () => false,
			isRegularItem: () => true,
			getAttachments: () => children.map((child) => child.id),
		};
		h.items.set(id, item);
		return item;
	};
	h.finishAll = async () => {
		const sessions = Array.from(h.preview._sessions);
		for (const proc of h.processes) proc.finish();
		await Promise.all(sessions.map((session) => session.done));
	};
	return h;
}

const highlight = () => ({ annotationIsExternal: false, annotationType: "highlight" });

test("PDF preview exports Zotero highlights into a temporary copy without transferring them", async () => {
	const h = harness();
	const annotation = highlight();
	const attachment = h.attachment(1, "/library/paper.pdf", [annotation]);
	assert.equal(await h.preview._openQuickLook([attachment]), true);
	assert.equal(h.exports.length, 1);
	const [id, exportedPath, includeAnnotations] = h.exports[0];
	assert.equal(id, attachment.id);
	assert.equal(includeAnnotations, true);
	assert.equal(h.exports[0].length, 3, "omit the transfer argument so source annotations are retained");
	assert.notEqual(exportedPath, "/library/paper.pdf");
	assert.ok(exportedPath.startsWith(h.preview._previewSession.tempDir + "/"));
	assert.equal(h.launches[0].command, "/bundle/pdfpreview");
	assert.deepEqual(Array.from(h.launches[0].arguments), [exportedPath]);
	assert.equal(h.files.get("/library/paper.pdf"), "original PDF bytes");
	assert.deepEqual(attachment.getAnnotations(), [annotation]);
	assert.equal(h.alerts.length, 0);
	await h.finishAll();
	assert.equal(h.files.has(exportedPath), false);
	assert.equal(h.files.has("/library/paper.pdf"), true);
});

test("PDFs without internal annotations use the original, including embedded annotations", async (t) => {
	for (const [name, annotations] of [
		["no annotations", []],
		["embedded annotation only", [{ annotationIsExternal: true, annotationType: "highlight" }]],
	]) {
		await t.test(name, async () => {
			const h = harness();
			const attachment = h.attachment(1, "/library/paper.PDF", annotations);
			await h.preview._openQuickLook([attachment]);
			assert.equal(h.exports.length, 0);
			assert.equal(h.launches[0].command, "/bundle/pdfpreview");
			assert.deepEqual(Array.from(h.launches[0].arguments), ["/library/paper.PDF"]);
			await h.finishAll();
		});
	}
});

test("reopening a PDF exports current annotations again instead of reusing an old copy", async () => {
	const h = harness();
	const annotations = [highlight()];
	const attachment = h.attachment(1, "/library/paper.pdf", annotations);
	await h.preview._openQuickLook([attachment]);
	await h.finishAll();
	annotations.push(highlight());
	await h.preview._openQuickLook([attachment]);
	assert.equal(h.exports.length, 2);
	assert.notEqual(h.exports[0][1], h.exports[1][1]);
	await h.finishAll();
});

test("annotation export errors never silently launch an unannotated PDF", async (t) => {
	for (const [name, handler] of [
		["worker rejects", async () => { throw new Error("Cannot export highlights"); }],
		["worker produces no output file", async () => {}],
	]) {
		await t.test(name, async () => {
			const h = harness();
			h.exportHandler = handler;
			const attachment = h.attachment(1, "/library/paper.pdf", [highlight()]);
			assert.equal(await h.preview._openQuickLook([attachment]), false);
			await h.finishAll();
			assert.equal(h.launches.length, 0);
			assert.equal(h.alerts.length, 1);
			assert.equal(h.preview._isActive, false);
			assert.equal(h.preview._launching, false);
			assert.equal(h.files.get("/library/paper.pdf"), "original PDF bytes");
		});
	}
});

test("a parent prefers its PDF and duplicate selected attachments export and launch only once", async () => {
	const h = harness();
	const text = h.attachment(1, "/library/readme.txt");
	const epub = h.attachment(2, "/library/book.epub");
	const pdf = h.attachment(3, "/library/paper.pdf", [highlight()]);
	const parent = h.parent(4, [text, epub, pdf]);
	await h.preview._openQuickLook([parent, pdf, parent]);
	assert.equal(h.exports.length, 1);
	assert.equal(h.exports[0][0], pdf.id);
	assert.equal(h.launches.length, 1);
	assert.deepEqual(Array.from(h.launches[0].arguments), [h.exports[0][1]]);
	await h.finishAll();
});

test("mixed selection opens PDFs in PDFKit and other files in Quick Look", async () => {
	const h = harness();
	const pdf = h.attachment(1, "/library/paper.pdf");
	const image = h.attachment(2, "/library/image.png");
	assert.equal(await h.preview._openQuickLook([pdf, image]), true);
	assert.equal(h.launches.length, 2);
	assert.deepEqual(h.launches.map((call) => [call.command, Array.from(call.arguments)]), [
		["/bundle/pdfpreview", ["/library/paper.pdf"]],
		["/usr/bin/qlmanage", ["-p", "/library/image.png"]],
	]);
	assert.equal(h.preview._previewSession.processes.size, 2);
	await h.finishAll();
});

test("a failed second launch closes the first viewer and cleans its PDF after exit", async () => {
	const h = harness();
	h.launchHandler = async ({ command }) => {
		if (command === "/usr/bin/qlmanage") throw new Error("Quick Look could not start");
	};
	const opening = h.preview._openQuickLook([
		h.attachment(1, "/library/paper.pdf", [highlight()]),
		h.attachment(2, "/library/image.png"),
	]);
	const session = h.preview._previewSession;
	assert.equal(await opening, false);
	assert.equal(h.launches.length, 2);
	assert.equal(h.processes[0].killed, 1);
	assert.equal(session.cancelled, true);
	assert.equal(h.preview._isActive, false);
	assert.equal(h.preview._previewSession, null);
	assert.equal(h.alerts.length, 1);
	assert.equal(h.files.has(h.exports[0][1]), true, "keep the exported PDF until the first child exits");
	assert.equal(h.removed.includes(session.tempDir), false);
	h.processes[0].finish();
	await session.done;
	assert.equal(h.files.has(h.exports[0][1]), false);
	assert.equal(h.removed.filter((name) => name === session.tempDir).length, 1);
	assert.equal(h.preview._sessions.size, 0);
});

test("path resolution without a preview session leaves annotation export disabled", async () => {
	const h = harness();
	const pdf = h.attachment(1, "/library/paper.pdf", [highlight()]);
	assert.deepEqual(Array.from(await h.preview._getPreviewPath([pdf])), ["/library/paper.pdf"]);
	assert.equal(h.exports.length, 0);
});

test("closing while annotation export is pending waits for preparation before cleanup", async () => {
	const h = harness();
	const started = deferred();
	const resume = deferred();
	h.exportHandler = async (_id, outputPath) => {
		started.resolve();
		await resume.promise;
		h.files.set(outputPath, "exported highlights");
	};
	const opening = h.preview._openQuickLook([h.attachment(1, "/library/paper.pdf", [highlight()])]);
	await started.promise;
	const session = h.preview._previewSession;
	h.preview._closeQuickLook();
	assert.equal(session.cancelled, true);
	assert.equal(h.removed.includes(session.tempDir), false);
	resume.resolve();
	assert.equal(await opening, false);
	await session.done;
	assert.equal(h.launches.length, 0);
	assert.equal(h.removed.includes(session.tempDir), true);
	assert.equal(h.files.has(h.exports[0][1]), false);
	assert.equal(h.alerts.length, 0);
});

test("closing while subprocess creation is pending kills the child when it arrives", async () => {
	const h = harness();
	const started = deferred();
	const resume = deferred();
	h.launchHandler = async () => { started.resolve(); await resume.promise; };
	const opening = h.preview._openQuickLook([h.attachment(1, "/library/paper.pdf")]);
	await started.promise;
	const session = h.preview._previewSession;
	h.preview._closeQuickLook();
	assert.equal(h.removed.includes(session.tempDir), false);
	resume.resolve();
	assert.equal(await opening, false);
	assert.equal(h.processes[0].killed, 1);
	assert.equal(h.removed.includes(session.tempDir), false, "the cancelled process may still have the PDF open");
	h.processes[0].finish();
	await session.done;
	assert.equal(h.removed.includes(session.tempDir), true);
	assert.equal(h.preview._isActive, false);
});

test("an old process exiting does not clear a newer preview session", async () => {
	const h = harness();
	const attachment = h.attachment(1, "/library/paper.pdf");
	await h.preview._openQuickLook([attachment]);
	const oldSession = h.preview._previewSession;
	await h.preview._openQuickLook([attachment]);
	const newSession = h.preview._previewSession;
	assert.notEqual(oldSession, newSession);
	assert.equal(h.processes[0].killed, 1);
	h.processes[0].finish();
	await oldSession.done;
	assert.equal(h.preview._previewSession, newSession);
	assert.equal(h.preview._isActive, true);
	assert.equal(h.removed.includes(newSession.tempDir), false);
	await h.finishAll();
});

test("closing a mixed preview kills all children and keeps temporary files until all exit", async () => {
	const h = harness();
	await h.preview._openQuickLook([
		h.attachment(1, "/library/paper.pdf", [highlight()]),
		h.attachment(2, "/library/image.png"),
	]);
	const session = h.preview._previewSession;
	const exportedPath = h.exports[0][1];
	h.preview._closeQuickLook();
	assert.deepEqual(h.processes.map((proc) => proc.killed), [1, 1]);
	h.processes[0].finish();
	await new Promise((resolve) => setImmediate(resolve));
	assert.equal(h.files.has(exportedPath), true);
	assert.equal(h.removed.includes(session.tempDir), false);
	h.processes[1].finish();
	await session.done;
	assert.equal(h.files.has(exportedPath), false);
	assert.equal(h.removed.filter((name) => name === session.tempDir).length, 1);
});

test("shutdown waits for child exit before deleting session files and shared helpers", async () => {
	const h = harness();
	await h.preview._openQuickLook([h.attachment(1, "/library/paper.pdf", [highlight()])]);
	const session = h.preview._previewSession;
	const tempRoot = h.preview._getTempDirPath();
	let finished = false;
	const shutdown = Promise.resolve(h.preview.shutdown()).then(() => { finished = true; });
	await new Promise((resolve) => setImmediate(resolve));
	assert.equal(h.processes[0].killed, 1);
	assert.equal(finished, false);
	assert.equal(h.removed.includes(session.tempDir), false);
	assert.equal(h.removed.includes(tempRoot), false);
	h.processes[0].finish();
	await shutdown;
	assert.ok(h.removed.indexOf(session.tempDir) < h.removed.indexOf(tempRoot));
	assert.equal(h.preview._sessions.size, 0);
});

test("a synced attachment with no local path is downloaded before preview", async () => {
	const h = harness();
	const attachment = h.attachment(1, "/library/remote.pdf");
	h.files.delete("/library/remote.pdf");
	let downloaded = false;
	attachment.getFilePathAsync = async () => downloaded ? "/library/remote.pdf" : false;
	h.downloadHandler = async () => {
		downloaded = true;
		h.files.set("/library/remote.pdf", "downloaded PDF");
	};
	assert.equal(await h.preview._openQuickLook([attachment]), true);
	assert.deepEqual(h.downloads, [attachment.id]);
	assert.deepEqual(Array.from(h.launches[0].arguments), ["/library/remote.pdf"]);
	await h.finishAll();
});
