#!/usr/bin/env node
// Uploads the Mac App Store listing texts in docs/store/locales/ to App Store Connect.
// Usage: node scripts/upload-store-metadata.mjs [--check-only | --dry-run] [options]
import { sign } from 'node:crypto';
import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const root = fileURLToPath(new URL('../', import.meta.url));
const localesDir = join(root, 'docs/store/locales');
const bundleId = 'com.ramnotes.RAMnotes';
const base = 'https://api.appstoreconnect.apple.com';

const { values } = parseArgs({
  options: {
    'key-path': { type: 'string', default: process.env.ASC_KEY_PATH },
    'key-id': { type: 'string', default: process.env.ASC_KEY_ID },
    'issuer-id': { type: 'string', default: process.env.ASC_ISSUER_ID },
    individual: { type: 'boolean' },
    'app-id': { type: 'string', default: process.env.ASC_APP_ID },
    version: { type: 'string' },
    locale: { type: 'string', multiple: true },
    'check-only': { type: 'boolean' },
    'dry-run': { type: 'boolean' },
    help: { type: 'boolean', short: 'h' },
  },
});

const usage = `Usage: node scripts/upload-store-metadata.mjs [options]

  --check-only        Validate docs/store/locales/*.md. No network access.
  --dry-run           Show the changes. Do not write to App Store Connect.
  --key-path PATH     App Store Connect API key (.p8). Env: ASC_KEY_PATH
  --key-id ID         Env: ASC_KEY_ID
  --issuer-id ID      Team key issuer. Env: ASC_ISSUER_ID
  --individual        Use an individual key (no issuer ID)
  --app-id ID         Apple ID of the app. Default: look up ${bundleId}. Env: ASC_APP_ID
  --version X.Y.Z     Select the editable macOS version when there is more than one
  --locale CODE       Upload only this locale (repeatable), e.g. --locale de-DE`;

// Section heading (without the "(N characters)" note) -> field and limit.
const fields = {
  name: { key: 'name', limit: 30, record: 'info' },
  subtitle: { key: 'subtitle', limit: 30, record: 'info' },
  'promotional text': { key: 'promotionalText', limit: 170, record: 'version' },
  keywords: { key: 'keywords', limit: 100, record: 'version' },
  description: { key: 'description', limit: 4000, record: 'version' },
};
const editableStates = new Set([
  'PREPARE_FOR_SUBMISSION',
  'DEVELOPER_REJECTED',
  'REJECTED',
  'METADATA_REJECTED',
  'INVALID_BINARY',
]);
const releasedStates = new Set([
  'READY_FOR_SALE',
  'READY_FOR_DISTRIBUTION',
  'DEVELOPER_REMOVED_FROM_SALE',
  'REMOVED_FROM_SALE',
  'REPLACED_WITH_NEW_VERSION',
]);

const length = (value) => Array.from(value).length;

function parseListing(locale, markdown) {
  const sections = {};
  let current;
  for (const line of markdown.split('\n')) {
    const heading = line.match(/^##\s+(.+?)\s*(?:\(.*\))?\s*$/);
    if (heading) {
      current = heading[1].toLowerCase();
      sections[current] = [];
    } else if (line.startsWith('# ')) {
      current = undefined;
    } else if (current) {
      sections[current].push(line);
    }
  }
  const listing = { info: {}, version: {} };
  for (const [heading, field] of Object.entries(fields)) {
    const value = sections[heading]?.join('\n').trim();
    const label = `${locale} ${heading}`;
    if (!value) throw new Error(`${label}: section is missing or empty.`);
    if (/\b(?:TODO|TBD|FIXME)\b/.test(value)) throw new Error(`${label}: remove placeholders.`);
    if (length(value) > field.limit)
      throw new Error(`${label}: ${length(value)} characters, limit is ${field.limit}.`);
    listing[field.record][field.key] = value;
  }
  const words = listing.version.keywords.split(',');
  if (words.some((word) => !word.trim() || word !== word.trim()))
    throw new Error(`${locale} keywords: use "a,b,c" with no empty items or spaces around commas.`);
  if (/[，、]/.test(listing.version.keywords))
    throw new Error(`${locale} keywords: separate with ASCII commas.`);
  if (new Set(words.map((word) => word.toLowerCase())).size !== words.length)
    throw new Error(`${locale} keywords: remove duplicates.`);
  return listing;
}

async function loadListings() {
  const files = (await readdir(localesDir)).filter((file) => file.endsWith('.md')).sort();
  const wanted = values.locale ? new Set(values.locale) : undefined;
  const listings = [];
  for (const file of files) {
    const locale = file.slice(0, -3);
    if (wanted && !wanted.has(locale)) continue;
    listings.push({ locale, ...parseListing(locale, await readFile(join(localesDir, file), 'utf8')) });
  }
  const missing = [...(wanted ?? [])].filter((locale) => !listings.some((l) => l.locale === locale));
  if (missing.length) throw new Error(`No listing file for: ${missing.join(', ')}.`);
  if (!listings.length) throw new Error(`No listing files in ${localesDir}.`);
  return listings;
}

async function createClient() {
  if (!values['key-path'] || !values['key-id'] || (!values.individual && !values['issuer-id']))
    throw new Error('Provide --key-path, --key-id, and either --issuer-id or --individual.');
  const privateKey = await readFile(values['key-path']);
  function jwt() {
    const now = Math.floor(Date.now() / 1000);
    const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
    const unsigned = [
      encode({ alg: 'ES256', kid: values['key-id'], typ: 'JWT' }),
      encode({
        ...(values.individual ? { sub: 'user' } : { iss: values['issuer-id'] }),
        iat: now,
        exp: now + 600,
        aud: 'appstoreconnect-v1',
      }),
    ].join('.');
    const signature = sign('sha256', Buffer.from(unsigned), {
      key: privateKey,
      dsaEncoding: 'ieee-p1363',
    });
    return `${unsigned}.${signature.toString('base64url')}`;
  }
  async function api(path, method = 'GET', body) {
    const url = new URL(path, base);
    if (url.origin !== base) throw new Error('Refusing to send credentials to another host.');
    const response = await fetch(url, {
      method,
      headers: { Authorization: `Bearer ${jwt()}`, 'Content-Type': 'application/json' },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(60000),
    });
    if (response.status === 204) return {};
    const result = await response.json();
    if (!response.ok) {
      const error = new Error(`${method} ${url.pathname}: ${response.status} ${JSON.stringify(result.errors)}`);
      error.status = response.status;
      throw error;
    }
    return result;
  }
  async function list(path) {
    const items = [];
    for (let next = path; next; ) {
      const page = await api(next);
      items.push(...page.data);
      next = page.links?.next;
    }
    return items;
  }
  return { api, list };
}

// Newer API responses use appVersionState / state; older ones use appStoreState.
const versionState = (a) => a.appVersionState ?? a.appStoreState;
const infoState = (a) => a.state ?? a.appStoreState;
const changedKeys = (actual, expected) =>
  Object.keys(expected).filter((key) => actual?.[key] !== expected[key]);

async function run() {
  if (values.help) return console.log(usage);
  if (values['check-only'] && values['dry-run']) throw new Error('Use --check-only or --dry-run, not both.');
  const listings = await loadListings();
  for (const { locale, info, version } of listings) {
    const counts = Object.entries({ ...info, ...version }).map(([k, v]) => `${k} ${length(v)}`);
    console.log(`${locale}: ${counts.join(', ')}`);
  }
  console.log(`Validated ${listings.length} listings.`);
  if (values['check-only']) return;

  const { api, list } = await createClient();
  let appId = values['app-id'];
  if (!appId) {
    const apps = await list(`/v1/apps?filter[bundleId]=${bundleId}&limit=200`);
    const app = apps.find((item) => item.attributes.bundleId === bundleId);
    if (!app) throw new Error(`No app with bundle ID ${bundleId}. Use --app-id.`);
    appId = app.id;
  }
  const versions = await list(`/v1/apps/${appId}/appStoreVersions?filter[platform]=MAC_OS&limit=200`);
  const candidates = versions.filter(
    ({ attributes: a }) =>
      editableStates.has(versionState(a)) && (!values.version || a.versionString === values.version),
  );
  if (candidates.length !== 1)
    throw new Error(`Found ${candidates.length} editable macOS versions. Create one or use --version.`);
  const version = candidates[0];
  const infos = (await list(`/v1/apps/${appId}/appInfos?limit=200`)).filter(({ attributes: a }) =>
    editableStates.has(infoState(a)),
  );
  if (infos.length !== 1) throw new Error(`Found ${infos.length} editable app information records.`);
  const appInfo = infos[0];
  const firstRelease = !versions.some(({ attributes: a }) => releasedStates.has(versionState(a)));
  console.log(
    `Target: app ${appId}, macOS ${version.attributes.versionString}${firstRelease ? ' (first release)' : ''}.`,
  );

  const parents = {
    info: {
      type: 'appInfoLocalizations',
      listPath: `/v1/appInfos/${appInfo.id}/appInfoLocalizations?limit=200`,
      relationships: { appInfo: { data: { type: 'appInfos', id: appInfo.id } } },
    },
    version: {
      type: 'appStoreVersionLocalizations',
      listPath: `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations?limit=200`,
      relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } } },
    },
  };
  const remote = {
    info: await list(parents.info.listPath),
    version: await list(parents.version.listPath),
  };
  const targets = listings.flatMap((listing) =>
    ['info', 'version'].map((record) => ({
      ...parents[record],
      record,
      locale: listing.locale,
      attributes: listing[record],
      existing: remote[record].find((item) => item.attributes.locale === listing.locale),
    })),
  );

  let planned = 0;
  for (const target of targets) {
    const keys = changedKeys(target.existing?.attributes, target.attributes);
    if (!keys.length) continue;
    planned++;
    console.log(`${target.existing ? 'Update' : 'Create'} ${target.type}/${target.locale}: ${keys.join(', ')}`);
  }
  if (!planned) return console.log('App Store Connect already matches the saved texts.');
  if (values['dry-run']) return console.log(`Dry run: ${planned} records need changes. Nothing was written.`);

  await mkdir(join(root, 'tmp'), { recursive: true });
  const backupPath = join(root, 'tmp', `store-metadata-before-${Date.now()}.json`);
  const backup = { appId, version: version.id, appInfo: appInfo.id, remote };
  await writeFile(backupPath, `${JSON.stringify(backup, null, 2)}\n`, { mode: 0o600 });
  console.log(`Saved the previous App Store Connect texts to ${backupPath}`);

  let changed = 0;
  for (const target of targets) {
    // Creating one localization can create its sibling for the same locale, so refresh first.
    if (!target.existing) {
      const refreshed = await list(target.listPath);
      target.existing = refreshed.find((item) => item.attributes.locale === target.locale);
    }
    const keys = changedKeys(target.existing?.attributes, target.attributes);
    let record = target.existing;
    if (keys.length) {
      const attributes = Object.fromEntries(keys.map((key) => [key, target.attributes[key]]));
      const body = record
        ? { data: { type: target.type, id: record.id, attributes } }
        : {
            data: {
              type: target.type,
              attributes: { ...target.attributes, locale: target.locale },
              relationships: target.relationships,
            },
          };
      ({ data: record } = await api(
        record ? `/v1/${target.type}/${record.id}` : `/v1/${target.type}`,
        record ? 'PATCH' : 'POST',
        body,
      ));
      changed++;
    }
    const { data: verified } = await api(`/v1/${target.type}/${record.id}`);
    const mismatches = changedKeys(verified.attributes, target.attributes);
    if (mismatches.length)
      throw new Error(`${target.type}/${target.locale}: verification failed for ${mismatches.join(', ')}.`);
    console.log(`Verified ${target.type}/${target.locale}.`);
  }
  console.log(`Uploaded and verified. ${changed} records changed. The app was not submitted for review.`);
}

try {
  await run();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
