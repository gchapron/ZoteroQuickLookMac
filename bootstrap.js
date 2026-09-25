/* eslint-disable no-unused-vars */
var QuickLook;

function log(msg) {
	Zotero.debug("QuickLook: " + msg);
}

function install() {
	log("Installed");
}

async function startup({ id, version, rootURI }) {
	log("Starting v" + version);

	Services.scriptloader.loadSubScript(rootURI + "quicklook.js");
	QuickLook.init({ id, version, rootURI });
	QuickLook.addToAllWindows();
}

function onMainWindowLoad({ window }) {
	QuickLook.addToWindow(window);
}

function onMainWindowUnload({ window }) {
	QuickLook.removeFromWindow(window);
}

async function shutdown() {
	log("Shutting down");
	QuickLook.removeFromAllWindows();
	await QuickLook.shutdown();
	QuickLook = undefined;
}

function uninstall() {
	log("Uninstalled");
}
