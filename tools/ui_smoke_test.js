#!/usr/bin/env node
// =============================================================================
// ui_smoke_test.js — Headless browser smoke test for UI validation (Milestone 29)
//
// Standalone Node.js script invoked by lib/ui_validate.sh.
// Uses Playwright if available, falls back to Puppeteer, then puppeteer-core
// with system Chromium.
//
// Usage:
//   node ui_smoke_test.js --url URL [options]
//
// Options:
//   --url URL                    Target URL (required)
//   --viewports "WxH,WxH"       Viewport sizes (default: "1280x800,375x812")
//   --timeout SECONDS            Page load timeout (default: 30)
//   --severity error|warn        Console severity that triggers failure (default: error)
//   --flicker-threshold FLOAT    Pixel diff ratio for flicker warning (default: 0.05)
//   --screenshot-dir DIR         Directory to save screenshots
//   --screenshots true|false     Whether to take screenshots (default: true)
//   --browser BROWSER            Browser hint from shell detection
//   --label LABEL                Label for this target in reports
//
// Output: One JSON line per viewport with test results.
// =============================================================================

const { createHash } = require('crypto');
const path = require('path');
const fs = require('fs');

// --- Argument parsing --------------------------------------------------------

function parseArgs() {
    const args = process.argv.slice(2);
    const opts = {
        url: '',
        viewports: '1280x800,375x812',
        timeout: 30,
        severity: 'error',
        flickerThreshold: 0.05,
        screenshotDir: '',
        screenshots: true,
        browser: '',
        label: 'unknown',
    };

    for (let i = 0; i < args.length; i++) {
        switch (args[i]) {
            case '--url': opts.url = args[++i] || ''; break;
            case '--viewports': opts.viewports = args[++i] || opts.viewports; break;
            case '--timeout': opts.timeout = parseInt(args[++i], 10) || 30; break;
            case '--severity': opts.severity = args[++i] || 'error'; break;
            case '--flicker-threshold': opts.flickerThreshold = parseFloat(args[++i]) || 0.05; break;
            case '--screenshot-dir': opts.screenshotDir = args[++i] || ''; break;
            case '--screenshots': opts.screenshots = args[++i] !== 'false'; break;
            case '--browser': opts.browser = args[++i] || ''; break;
            case '--label': opts.label = args[++i] || 'unknown'; break;
        }
    }

    if (!opts.url) {
        process.stderr.write('Error: --url is required\n');
        process.exit(2);
    }

    return opts;
}

// --- Browser launcher --------------------------------------------------------

async function launchBrowser(browserHint) {
    // Try Playwright first
    try {
        const pw = require('playwright');
        const browser = await pw.chromium.launch({ headless: true });
        return { browser, type: 'playwright' };
    } catch (_) { /* not available */ }

    // Try Puppeteer
    try {
        const ppt = require('puppeteer');
        const browser = await ppt.launch({ headless: 'new' });
        return { browser, type: 'puppeteer' };
    } catch (_) { /* not available */ }

    // Try puppeteer-core with system browser
    if (browserHint && browserHint.startsWith('system:')) {
        const execPath = browserHint.slice(7);
        try {
            const pptCore = require('puppeteer-core');
            const browser = await pptCore.launch({
                headless: 'new',
                executablePath: execPath,
            });
            return { browser, type: 'puppeteer-core' };
        } catch (_) { /* not available */ }
    }

    // Try common system paths
    const systemPaths = [
        '/usr/bin/chromium-browser',
        '/usr/bin/chromium',
        '/usr/bin/google-chrome',
        '/usr/bin/google-chrome-stable',
    ];

    for (const sysPath of systemPaths) {
        if (fs.existsSync(sysPath)) {
            try {
                const pptCore = require('puppeteer-core');
                const browser = await pptCore.launch({
                    headless: 'new',
                    executablePath: sysPath,
                });
                return { browser, type: 'puppeteer-core' };
            } catch (_) { /* try next */ }
        }
    }

    process.stderr.write('Error: No headless browser available\n');
    process.exit(1);
}

// --- Screenshot hash for flicker detection -----------------------------------

function hashBuffer(buf) {
    return createHash('sha256').update(buf).digest('hex');
}

function pixelDiffRatio(hash1, hash2) {
    // Simple: if hashes differ at all, we estimate difference based on
    // character-level hamming distance of hex hashes (rough approximation)
    if (hash1 === hash2) return 0;
    let diff = 0;
    const len = Math.min(hash1.length, hash2.length);
    for (let i = 0; i < len; i++) {
        if (hash1[i] !== hash2[i]) diff++;
    }
    return diff / len;
}

// --- Core smoke test ---------------------------------------------------------

async function runSmokeTest(browserCtx, url, viewport, opts) {
    const result = {
        label: opts.label,
        viewport: `${viewport.width}x${viewport.height}`,
        url: url,
        load: 'pass',
        console: 'pass',
        resources: 'pass',
        rendering: 'pass',
        flicker: 'none',
        verdict: 'PASS',
        console_errors: [],
        missing_resources: [],
        screenshots: [],
    };

    const consoleMessages = [];
    const resourceErrors = [];
    let page;

    try {
        if (browserCtx.type === 'playwright') {
            const context = await browserCtx.browser.newContext({
                viewport: { width: viewport.width, height: viewport.height },
            });
            page = await context.newPage();

            // Console listener
            page.on('console', msg => {
                if (msg.type() === 'error') {
                    consoleMessages.push({ level: 'error', text: msg.text() });
                } else if (msg.type() === 'warning') {
                    consoleMessages.push({ level: 'warn', text: msg.text() });
                }
            });

            // Page error listener
            page.on('pageerror', err => {
                consoleMessages.push({ level: 'error', text: `Uncaught: ${err.message}` });
            });

            // Resource error listener
            page.on('response', response => {
                if (response.status() === 404) {
                    resourceErrors.push(response.url());
                }
            });

            // Navigate
            try {
                await page.goto(url, {
                    timeout: opts.timeout * 1000,
                    waitUntil: 'load',
                });
            } catch (navErr) {
                result.load = 'fail';
                result.verdict = 'FAIL';
                result.console_errors.push(`Load failed: ${navErr.message}`);
                return result;
            }

            // Wait for additional resources and JS execution
            await page.waitForTimeout(3000);

            // Check body dimensions
            const bodySize = await page.evaluate(() => {
                const body = document.body;
                if (!body) return { width: 0, height: 0, children: 0 };
                return {
                    width: body.offsetWidth,
                    height: body.offsetHeight,
                    children: body.children.length,
                };
            });

            if (bodySize.width === 0 || bodySize.height === 0 || bodySize.children === 0) {
                result.rendering = 'fail';
            }

            // Flicker detection: take 3 screenshots at 2s intervals
            const hashes = [];
            for (let i = 0; i < 3; i++) {
                if (i > 0) await page.waitForTimeout(2000);
                const buf = await page.screenshot({ fullPage: true });
                hashes.push(hashBuffer(buf));

                if (opts.screenshots && opts.screenshotDir) {
                    const ts = Date.now();
                    const runDir = path.join(opts.screenshotDir, `run_${ts}`);
                    fs.mkdirSync(runDir, { recursive: true });
                    const fname = `${opts.label}_${viewport.width}x${viewport.height}_frame${i}.png`;
                    fs.writeFileSync(path.join(runDir, fname), buf);
                    result.screenshots.push(path.join(runDir, fname));
                }
            }

            // Check flicker
            for (let i = 1; i < hashes.length; i++) {
                const ratio = pixelDiffRatio(hashes[i - 1], hashes[i]);
                if (ratio > opts.flickerThreshold) {
                    result.flicker = 'detected';
                    break;
                }
            }

            await page.close();

        } else {
            // Puppeteer / puppeteer-core path
            page = await browserCtx.browser.newPage();
            await page.setViewport({ width: viewport.width, height: viewport.height });

            // Console listener
            page.on('console', msg => {
                const type = msg.type();
                if (type === 'error') {
                    consoleMessages.push({ level: 'error', text: msg.text() });
                } else if (type === 'warning') {
                    consoleMessages.push({ level: 'warn', text: msg.text() });
                }
            });

            page.on('pageerror', err => {
                consoleMessages.push({ level: 'error', text: `Uncaught: ${err.message}` });
            });

            page.on('response', response => {
                if (response.status() === 404) {
                    resourceErrors.push(response.url());
                }
            });

            // Navigate
            try {
                await page.goto(url, {
                    timeout: opts.timeout * 1000,
                    waitUntil: 'load',
                });
            } catch (navErr) {
                result.load = 'fail';
                result.verdict = 'FAIL';
                result.console_errors.push(`Load failed: ${navErr.message}`);
                return result;
            }

            // Wait for JS execution
            await new Promise(r => setTimeout(r, 3000));

            // Check body dimensions
            const bodySize = await page.evaluate(() => {
                const body = document.body;
                if (!body) return { width: 0, height: 0, children: 0 };
                return {
                    width: body.offsetWidth,
                    height: body.offsetHeight,
                    children: body.children.length,
                };
            });

            if (bodySize.width === 0 || bodySize.height === 0 || bodySize.children === 0) {
                result.rendering = 'fail';
            }

            // Flicker detection
            const hashes = [];
            for (let i = 0; i < 3; i++) {
                if (i > 0) await new Promise(r => setTimeout(r, 2000));
                const buf = await page.screenshot({ fullPage: true });
                hashes.push(hashBuffer(buf));

                if (opts.screenshots && opts.screenshotDir) {
                    const ts = Date.now();
                    const runDir = path.join(opts.screenshotDir, `run_${ts}`);
                    fs.mkdirSync(runDir, { recursive: true });
                    const fname = `${opts.label}_${viewport.width}x${viewport.height}_frame${i}.png`;
                    fs.writeFileSync(path.join(runDir, fname), buf);
                    result.screenshots.push(path.join(runDir, fname));
                }
            }

            for (let i = 1; i < hashes.length; i++) {
                const ratio = pixelDiffRatio(hashes[i - 1], hashes[i]);
                if (ratio > opts.flickerThreshold) {
                    result.flicker = 'detected';
                    break;
                }
            }

            await page.close();
        }

    } catch (err) {
        result.load = 'fail';
        result.verdict = 'FAIL';
        result.console_errors.push(`Error: ${err.message}`);
        return result;
    }

    // Process collected errors
    const severityLevel = opts.severity === 'warn' ? ['error', 'warn'] : ['error'];

    const failingConsoleErrors = consoleMessages.filter(m => severityLevel.includes(m.level));
    if (failingConsoleErrors.length > 0) {
        result.console = 'fail';
        result.console_errors = failingConsoleErrors.map(m => m.text);
    }

    if (resourceErrors.length > 0) {
        result.resources = 'fail';
        result.missing_resources = resourceErrors;
    }

    // Determine verdict
    if (result.load === 'fail' || result.console === 'fail' ||
        result.resources === 'fail' || result.rendering === 'fail') {
        result.verdict = 'FAIL';
    } else if (result.flicker === 'detected') {
        result.verdict = 'WARN';
    }

    return result;
}

// --- Main --------------------------------------------------------------------

async function main() {
    const opts = parseArgs();
    const viewports = opts.viewports.split(',').map(v => {
        const [w, h] = v.trim().split('x').map(Number);
        return { width: w || 1280, height: h || 800 };
    });

    let browserCtx;
    try {
        browserCtx = await launchBrowser(opts.browser);
    } catch (err) {
        process.stderr.write(`Failed to launch browser: ${err.message}\n`);
        process.exit(1);
    }

    try {
        for (const viewport of viewports) {
            const result = await runSmokeTest(browserCtx, opts.url, viewport, opts);
            // Output one JSON line per viewport
            process.stdout.write(JSON.stringify(result) + '\n');
        }
    } finally {
        await browserCtx.browser.close();
    }
}

main().catch(err => {
    process.stderr.write(`Fatal: ${err.message}\n`);
    process.exit(1);
});
