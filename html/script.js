(() => {
    'use strict';

    const dom = {
        app: document.getElementById('app'),
        modeBadge: document.getElementById('modeBadge'),
        modeBadgeText: document.getElementById('modeBadgeText'),
        fieldTotal: document.getElementById('fieldTotal'),
        sectionNav: document.getElementById('sectionNav'),
        permissionCard: document.getElementById('permissionCard'),
        closeButton: document.getElementById('closeButton'),
        breadcrumbVehicle: document.getElementById('breadcrumbVehicle'),
        vehicleName: document.getElementById('vehicleName'),
        vehicleModel: document.getElementById('vehicleModel'),
        handlingName: document.getElementById('handlingName'),
        resourceName: document.getElementById('resourceName'),
        sourcePath: document.getElementById('sourcePath'),
        readonlyBanner: document.getElementById('readonlyBanner'),
        fieldSearch: document.getElementById('fieldSearch'),
        saveIndicator: document.getElementById('saveIndicator'),
        saveIndicatorText: document.getElementById('saveIndicatorText'),
        emptyState: document.getElementById('emptyState'),
        fieldGroups: document.getElementById('fieldGroups'),
        restartButton: document.getElementById('restartButton'),
        restartModal: document.getElementById('restartModal'),
        restartResourceName: document.getElementById('restartResourceName'),
        cancelRestart: document.getElementById('cancelRestart'),
        confirmRestart: document.getElementById('confirmRestart'),
        toastRegion: document.getElementById('toastRegion'),
        restartLoading: document.getElementById('restartLoading'),
        restartLoadingResource: document.getElementById('restartLoadingResource'),
        restartLoadingStage: document.getElementById('restartLoadingStage'),
        restartLoadingDetail: document.getElementById('restartLoadingDetail'),
    };

    const state = {
        open: false,
        sessionId: null,
        canEdit: false,
        nuiResource: 'cHandlingEditor',
        vehicleResource: '',
        fields: new Map(),
        groups: [],
        groupOffsets: [],
        activeGroupId: null,
        statusTimer: null,
        restarting: false,
        restartSupported: true,
    };

    const groupIconMarkup = `
        <svg viewBox="0 0 24 24" fill="none" aria-hidden="true">
            <path d="M5 6h14M5 12h14M5 18h14" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>
            <circle cx="8" cy="6" r="1.5" fill="currentColor"/>
            <circle cx="16" cy="12" r="1.5" fill="currentColor"/>
            <circle cx="10" cy="18" r="1.5" fill="currentColor"/>
        </svg>`;

    const resetIconMarkup = `
        <svg viewBox="0 0 20 20" fill="none" aria-hidden="true">
            <path d="M4 7V3.5M4 3.5h3.5M4.2 3.8A7 7 0 1 1 3 12" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>`;

    function deepCopy(value) {
        if (value === undefined || value === null || typeof value !== 'object') return value;
        if (Array.isArray(value)) return value.map(deepCopy);
        const copy = {};
        Object.keys(value).forEach((key) => { copy[key] = deepCopy(value[key]); });
        return copy;
    }

    function hasOwn(object, property) {
        return Object.prototype.hasOwnProperty.call(object, property);
    }

    function safeText(value, fallback = '—') {
        if (value === undefined || value === null || value === '') return fallback;
        return String(value);
    }

    function normalizeType(field) {
        const rawType = String(field.type || '').toLowerCase();
        if (rawType === 'float' || rawType === 'number') return 'number';
        if (rawType === 'int' || rawType === 'integer') return 'integer';
        if (rawType === 'vector' || rawType === 'vector3') return 'vector';
        if (rawType === 'string' || rawType === 'text' || rawType === 'flags') return 'text';

        const value = field.value;
        if (value && typeof value === 'object' && !Array.isArray(value)) return 'vector';
        if (typeof value === 'number') return 'number';
        return 'text';
    }

    function finiteNumber(value) {
        if (typeof value !== 'number' && typeof value !== 'string') return null;
        if (typeof value === 'string' && value.trim() === '') return null;
        const parsed = typeof value === 'number' ? value : Number(value.trim());
        return Number.isFinite(parsed) ? parsed : null;
    }

    function normalizeVector(value) {
        if (!value || typeof value !== 'object') return { x: 0, y: 0, z: 0 };
        const x = finiteNumber(value.x ?? value.X ?? value[0]);
        const y = finiteNumber(value.y ?? value.Y ?? value[1]);
        const z = finiteNumber(value.z ?? value.Z ?? value[2]);
        return {
            x: x === null ? 0 : x,
            y: y === null ? 0 : y,
            z: z === null ? 0 : z,
        };
    }

    function normalizeInitialValue(type, value) {
        if (type === 'vector') return normalizeVector(value);
        if (type === 'number' || type === 'integer') {
            const parsed = finiteNumber(value);
            return parsed === null ? value : parsed;
        }
        return value === undefined || value === null ? '' : String(value);
    }

    function valuesEqual(left, right) {
        if (left && right && typeof left === 'object' && typeof right === 'object') {
            return ['x', 'y', 'z'].every((axis) => Number(left[axis]) === Number(right[axis]));
        }
        if (typeof left === 'number' || typeof right === 'number') return Number(left) === Number(right);
        return String(left ?? '') === String(right ?? '');
    }

    function formatInputValue(value) {
        if (value === undefined || value === null) return '';
        return String(value);
    }

    async function postNui(endpoint, payload = {}) {
        const resource = typeof GetParentResourceName === 'function'
            ? GetParentResourceName()
            : state.nuiResource;
        const response = await fetch(`https://${resource}/${endpoint}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(payload),
        });

        if (!response.ok) throw new Error(`NUI request failed (${response.status})`);
        const text = await response.text();
        if (!text) return {};
        return JSON.parse(text);
    }

    function showToast(message, type = 'info', duration = 4200) {
        if (!message) return;
        const toast = document.createElement('div');
        toast.className = `toast toast--${type}`;
        toast.textContent = String(message);
        dom.toastRegion.appendChild(toast);

        window.setTimeout(() => {
            toast.classList.add('toast--leaving');
            window.setTimeout(() => toast.remove(), 180);
        }, duration);
    }

    function setGlobalStatus(status, message, sticky = false) {
        if (state.statusTimer) {
            window.clearTimeout(state.statusTimer);
            state.statusTimer = null;
        }

        if (dom.saveIndicator.dataset.state !== status) dom.saveIndicator.dataset.state = status;
        if (dom.saveIndicatorText.textContent !== message) dom.saveIndicatorText.textContent = message;

        if (!sticky && (status === 'saved' || status === 'error')) {
            state.statusTimer = window.setTimeout(() => refreshGlobalStatus(), status === 'error' ? 4500 : 2200);
        }
    }

    function refreshGlobalStatus() {
        if (!state.open) return;
        let pending = 0;
        let dirty = 0;
        state.fields.forEach((field) => {
            if (field.pending) pending += 1;
            else if (field.status === 'dirty') dirty += 1;
        });

        if (pending > 0) {
            dom.restartButton.disabled = true;
            setGlobalStatus('saving', pending === 1 ? 'Saving change…' : `Saving ${pending} changes…`, true);
        } else if (dirty > 0) {
            dom.restartButton.disabled = true;
            setGlobalStatus('idle', dirty === 1 ? '1 edited field not committed' : `${dirty} edited fields not committed`, true);
        } else if (!state.canEdit) {
            dom.restartButton.disabled = true;
            setGlobalStatus('idle', 'Viewing source values', true);
        } else if (state.restartSupported) {
            dom.restartButton.disabled = false;
            setGlobalStatus('saved', 'All changes saved', true);
        } else {
            dom.restartButton.disabled = true;
            setGlobalStatus('saved', 'All changes applied live', true);
        }
    }

    function setFieldStatus(model, status, message) {
        const changed = model.status !== status || model.statusElement.textContent !== message;
        model.status = status;
        if (!changed) return false;

        if (model.card.dataset.status !== status) model.card.dataset.status = status;
        if (model.statusElement.textContent !== message) model.statusElement.textContent = message;
        const invalid = status === 'error' || status === 'conflict';
        const invalidValue = invalid ? 'true' : 'false';
        model.inputs.forEach((input) => {
            if (input.getAttribute('aria-invalid') !== invalidValue) {
                input.setAttribute('aria-invalid', invalidValue);
            }
        });
        return true;
    }

    function setFieldDisabled(model, disabled) {
        const shouldDisable = disabled || !state.canEdit;
        model.inputs.forEach((input) => {
            if (input.disabled !== shouldDisable) input.disabled = shouldDisable;
        });
        updateResetButton(model);
    }

    function readFieldValue(model) {
        if (model.type === 'vector') {
            const values = {};
            for (const input of model.inputs) {
                const parsed = finiteNumber(input.value.trim());
                if (parsed === null) throw new Error(`Component ${input.dataset.axis.toUpperCase()} must be a finite number.`);
                values[input.dataset.axis] = parsed;
            }
            return values;
        }

        const raw = model.inputs[0].value;
        if (model.type === 'number') {
            const parsed = finiteNumber(raw.trim());
            if (parsed === null) throw new Error('Enter a finite number.');
            return parsed;
        }
        if (model.type === 'integer') {
            const parsed = finiteNumber(raw.trim());
            if (parsed === null || !Number.isInteger(parsed)) throw new Error('Enter a whole number.');
            return parsed;
        }
        return raw;
    }

    function writeFieldValue(model, value) {
        const normalized = normalizeInitialValue(model.type, value);
        if (model.type === 'vector') {
            model.inputs.forEach((input) => {
                input.value = formatInputValue(normalized[input.dataset.axis]);
            });
        } else {
            model.inputs[0].value = formatInputValue(normalized);
        }
        updateResetButton(model);
    }

    function currentValueOrNull(model) {
        try {
            return readFieldValue(model);
        } catch (_) {
            return null;
        }
    }

    function updateResetButton(model) {
        const current = currentValueOrNull(model);
        const disabled = !state.canEdit
            || Boolean(model.pending)
            || (current !== null && valuesEqual(current, model.originalValue));
        if (model.resetButton.disabled !== disabled) model.resetButton.disabled = disabled;
    }

    function markFieldDirty(model) {
        if (!state.canEdit || model.pending) return;

        let statusChanged;
        try {
            const value = readFieldValue(model);
            if (valuesEqual(value, model.savedValue)) {
                statusChanged = setFieldStatus(model, 'idle', 'No unsaved changes');
            } else {
                statusChanged = setFieldStatus(model, 'dirty', 'Edited · press Enter or leave field');
            }
        } catch (error) {
            statusChanged = setFieldStatus(model, 'error', error.message);
        }
        updateResetButton(model);
        if (statusChanged) refreshGlobalStatus();
    }

    async function commitField(model) {
        if (!state.open || !state.canEdit || model.pending) return;

        let value;
        try {
            value = readFieldValue(model);
        } catch (error) {
            setFieldStatus(model, 'error', error.message);
            setGlobalStatus('error', 'Fix the invalid field before saving');
            showToast(error.message, 'error');
            return;
        }

        if (valuesEqual(value, model.savedValue)) {
            setFieldStatus(model, 'saved', 'Already saved');
            refreshGlobalStatus();
            return;
        }

        const pending = {
            requestId: null,
            submittedValue: deepCopy(value),
            previousValue: deepCopy(model.savedValue),
        };
        model.pending = pending;
        setFieldDisabled(model, true);
        setFieldStatus(model, 'saving', model.live ? 'Applying live & saving…' : 'Writing to handling file…');
        refreshGlobalStatus();

        try {
            const response = await postNui('saveField', {
                fieldId: model.id,
                value,
                expectedValue: deepCopy(model.savedValue),
            });

            if (model.pending !== pending) return;
            if (!response || response.ok !== true) {
                throw new Error(response && response.error ? response.error : 'The change was rejected.');
            }
            pending.requestId = response.requestId ? String(response.requestId) : null;
        } catch (error) {
            if (model.pending !== pending) return;
            model.pending = null;
            writeFieldValue(model, pending.previousValue);
            setFieldDisabled(model, false);
            setFieldStatus(model, 'error', error.message || 'Unable to save this field');
            setGlobalStatus('error', 'A change could not be saved');
            showToast(error.message || 'Unable to save this field.', 'error');
        }
    }

    function handleSaveResult(payload) {
        const model = state.fields.get(String(payload.fieldId));
        if (!model || !model.pending) return;

        const pending = model.pending;
        if (pending.requestId && payload.requestId && pending.requestId !== String(payload.requestId)) return;
        model.pending = null;

        if (payload.restartRequired !== undefined) {
            model.restartRequired = payload.restartRequired === true;
            updateRestartBadge(model);
        }

        if (payload.ok === true) {
            const savedValue = hasOwn(payload, 'value') && payload.value !== null
                ? normalizeInitialValue(model.type, payload.value)
                : pending.submittedValue;
            model.savedValue = deepCopy(savedValue);
            writeFieldValue(model, savedValue);
            setFieldDisabled(model, false);

            if (payload.liveWarning) {
                setFieldStatus(model, 'saved', 'Saved · preview unavailable · restart required');
                showToast(`${model.label} was saved, but live verification failed. Restart the resource to apply it.`, 'warning');
            } else if (model.restartRequired || !model.live) {
                setFieldStatus(model, 'saved', 'Saved · resource restart required');
            } else {
                setFieldStatus(model, 'saved', 'Saved and applied live');
            }
            setGlobalStatus('saved', 'Change saved automatically');
        } else {
            const hasAuthoritativeValue = payload.conflict === true && hasOwn(payload, 'value') && payload.value !== null;
            const restoredValue = hasAuthoritativeValue
                ? normalizeInitialValue(model.type, payload.value)
                : pending.previousValue;
            model.savedValue = deepCopy(restoredValue);
            writeFieldValue(model, restoredValue);
            setFieldDisabled(model, false);

            const error = payload.error || (payload.conflict
                ? 'The file changed outside this session. The latest value has been loaded.'
                : 'The server rejected this change.');
            setFieldStatus(model, payload.conflict ? 'conflict' : 'error', error);
            setGlobalStatus('error', payload.conflict ? 'Edit conflict detected' : 'A change could not be saved');
            showToast(error, payload.conflict ? 'warning' : 'error', 6000);
        }

        updateResetButton(model);
        if (Array.from(state.fields.values()).some((field) => field.pending)) refreshGlobalStatus();
    }

    function createBadge(text, className) {
        const badge = document.createElement('span');
        badge.className = `field-badge ${className}`;
        badge.textContent = text;
        return badge;
    }

    function updateRestartBadge(model) {
        if (model.restartRequired && !model.restartBadge) {
            model.restartBadge = createBadge('Restart', 'field-badge--restart');
            model.badges.appendChild(model.restartBadge);
        } else if (!model.restartRequired && model.restartBadge) {
            model.restartBadge.remove();
            model.restartBadge = null;
        }
    }

    function createInput(model, axis = null) {
        const input = document.createElement('input');
        input.className = 'field-input';
        input.type = 'text';
        input.autocomplete = 'off';
        input.spellcheck = false;
        input.dataset.fieldId = model.id;
        if (axis) input.dataset.axis = axis;
        input.inputMode = model.type === 'text' ? 'text' : (model.type === 'integer' ? 'numeric' : 'decimal');
        input.setAttribute('aria-label', axis ? `${model.label} ${axis.toUpperCase()}` : model.label);
        input.disabled = !state.canEdit;

        input.addEventListener('input', () => markFieldDirty(model));
        input.addEventListener('keydown', (event) => {
            if (event.key !== 'Enter') return;
            event.preventDefault();
            void commitField(model);
        });
        input.addEventListener('focusout', () => {
            window.setTimeout(() => {
                if (!model.card.contains(document.activeElement)) void commitField(model);
            }, 0);
        });
        return input;
    }

    function createFieldCard(rawField, group, fieldIndex) {
        if (!rawField || rawField.id === undefined || rawField.id === null) return null;

        const id = String(rawField.id);
        const type = normalizeType(rawField);
        const nativeName = rawField.name || rawField.field || rawField.fieldName || rawField.nativeName || id;
        const className = rawField.class || rawField.className || rawField.handlingClass || rawField.nativeClass || group.className || 'CHandlingData';
        const label = safeText(rawField.label || rawField.title || nativeName, `Field ${fieldIndex + 1}`);
        const initialValue = normalizeInitialValue(type, rawField.value);

        const model = {
            id,
            raw: rawField,
            type,
            label,
            nativeName: String(nativeName),
            className: String(className),
            live: rawField.live === true,
            restartRequired: rawField.restartRequired === true,
            originalValue: deepCopy(initialValue),
            savedValue: deepCopy(initialValue),
            pending: null,
            status: 'idle',
            inputs: [],
            restartBadge: null,
        };

        const card = document.createElement('article');
        card.className = `field-card${type === 'vector' ? ' field-card--vector' : ''}`;
        card.dataset.status = 'idle';
        card.dataset.fieldId = id;

        const header = document.createElement('div');
        header.className = 'field-card__header';

        const title = document.createElement('div');
        title.className = 'field-card__title';
        const name = document.createElement('span');
        name.className = 'field-card__name';
        name.textContent = label;
        name.title = label;
        const code = document.createElement('span');
        code.className = 'field-card__code';
        code.textContent = `${className}.${nativeName}`;
        code.title = `${className}.${nativeName}`;
        title.append(name, code);

        const badges = document.createElement('div');
        badges.className = 'field-card__badges';
        badges.appendChild(model.live
            ? createBadge('Live', 'field-badge--live')
            : createBadge('File only', 'field-badge--file'));
        model.badges = badges;
        updateRestartBadge(model);
        header.append(title, badges);

        const inputArea = document.createElement('div');
        if (type === 'vector') {
            inputArea.className = 'vector-inputs';
            ['x', 'y', 'z'].forEach((axis) => {
                const wrapper = document.createElement('div');
                wrapper.className = 'vector-input';
                const component = document.createElement('span');
                component.className = 'component-label';
                component.textContent = axis.toUpperCase();
                const input = createInput(model, axis);
                model.inputs.push(input);
                wrapper.append(component, input);
                inputArea.appendChild(wrapper);
            });
        } else {
            inputArea.className = 'input-shell';
            const input = createInput(model);
            model.inputs.push(input);
            inputArea.appendChild(input);
        }

        const footer = document.createElement('div');
        footer.className = 'field-card__footer';
        const status = document.createElement('span');
        status.className = 'field-status';
        status.textContent = state.canEdit ? 'No unsaved changes' : 'View only';

        const reset = document.createElement('button');
        reset.type = 'button';
        reset.className = 'reset-button';
        reset.innerHTML = `${resetIconMarkup}<span>Reset</span>`;
        reset.title = 'Restore the value from when this session opened';
        reset.addEventListener('click', () => {
            if (!state.canEdit || model.pending) return;
            writeFieldValue(model, model.originalValue);
            markFieldDirty(model);
            void commitField(model);
        });
        footer.append(status, reset);

        card.append(header, inputArea, footer);
        model.card = card;
        model.statusElement = status;
        model.resetButton = reset;
        model.searchText = [label, nativeName, className, group.label, type, model.live ? 'live' : 'file only']
            .join(' ')
            .toLocaleLowerCase();

        writeFieldValue(model, initialValue);
        setFieldDisabled(model, false);
        state.fields.set(id, model);
        return card;
    }

    function createGroup(rawGroup, groupIndex) {
        const rawFields = Array.isArray(rawGroup && rawGroup.fields) ? rawGroup.fields : [];
        const groupId = `handling-group-${groupIndex}`;
        const label = safeText(rawGroup && (rawGroup.label || rawGroup.name || rawGroup.title), `Group ${groupIndex + 1}`);
        const description = safeText(rawGroup && rawGroup.description, `${rawFields.length} handling field${rawFields.length === 1 ? '' : 's'}`);
        const className = rawGroup && (rawGroup.class || rawGroup.className || rawGroup.handlingClass);

        const section = document.createElement('section');
        section.className = 'group-section';
        section.id = groupId;

        const header = document.createElement('header');
        header.className = 'group-section__header';
        const icon = document.createElement('span');
        icon.className = 'group-section__icon';
        icon.innerHTML = groupIconMarkup;
        const heading = document.createElement('div');
        heading.className = 'group-section__title';
        const title = document.createElement('h3');
        title.textContent = label;
        const subtitle = document.createElement('p');
        subtitle.textContent = description;
        heading.append(title, subtitle);
        const line = document.createElement('span');
        line.className = 'group-section__line';
        header.append(icon, heading, line);

        const grid = document.createElement('div');
        grid.className = 'field-grid';
        const models = [];
        rawFields.forEach((field, fieldIndex) => {
            const card = createFieldCard(field, { label, className }, fieldIndex);
            if (!card) return;
            grid.appendChild(card);
            models.push(state.fields.get(String(field.id)));
        });
        section.append(header, grid);

        const nav = document.createElement('button');
        nav.type = 'button';
        nav.className = 'section-link';
        nav.innerHTML = `<span class="section-link__icon">${groupIconMarkup}</span>`;
        const navLabel = document.createElement('span');
        navLabel.className = 'section-link__label';
        navLabel.textContent = label;
        navLabel.title = label;
        const navCount = document.createElement('span');
        navCount.className = 'section-link__count';
        navCount.textContent = String(models.length);
        nav.append(navLabel, navCount);
        nav.addEventListener('click', () => {
            section.scrollIntoView({ behavior: 'auto', block: 'start' });
            setActiveGroup(groupId);
        });

        return {
            id: groupId,
            label,
            searchText: label.toLocaleLowerCase(),
            section,
            nav,
            models,
        };
    }

    function setActiveGroup(groupId) {
        if (!groupId || state.activeGroupId === groupId) return;
        state.activeGroupId = groupId;
        state.groups.forEach((group) => {
            group.nav.classList.toggle('section-link--active', group.id === groupId);
        });
    }

    function rebuildGroupOffsets() {
        if (!state.open) {
            state.groupOffsets = [];
            return;
        }

        const containerTop = dom.fieldGroups.getBoundingClientRect().top;
        const scrollTop = dom.fieldGroups.scrollTop;
        state.groupOffsets = state.groups
            .filter((group) => !group.section.hidden)
            .map((group) => ({
                id: group.id,
                top: group.section.getBoundingClientRect().top - containerTop + scrollTop,
            }));
    }

    let layoutFrame = null;
    function scheduleGroupOffsetRefresh() {
        if (layoutFrame !== null) return;
        layoutFrame = window.requestAnimationFrame(() => {
            layoutFrame = null;
            rebuildGroupOffsets();
            updateActiveGroupFromScroll();
        });
    }

    function updateActiveGroupFromScroll() {
        if (!state.open) return;
        const offsets = state.groupOffsets;
        if (offsets.length === 0) return;

        const scrollPosition = dom.fieldGroups.scrollTop + 12;
        let selected = offsets[0].id;
        for (const group of offsets) {
            if (group.top > scrollPosition) break;
            selected = group.id;
        }
        if (selected) setActiveGroup(selected);
    }

    function applySearch() {
        const query = dom.fieldSearch.value.trim().toLocaleLowerCase();
        let visibleFields = 0;

        state.groups.forEach((group) => {
            const groupMatches = query !== '' && group.searchText.includes(query);
            let groupVisible = 0;

            group.models.forEach((model) => {
                const matches = query === '' || groupMatches || model.searchText.includes(query);
                if (model.card.hidden === matches) model.card.hidden = !matches;
                if (matches) groupVisible += 1;
            });

            const groupHidden = groupVisible === 0;
            if (group.section.hidden !== groupHidden) group.section.hidden = groupHidden;
            if (group.nav.hidden !== groupHidden) group.nav.hidden = groupHidden;
            visibleFields += groupVisible;
        });

        dom.emptyState.hidden = visibleFields > 0;
        const firstVisible = state.groups.find((group) => !group.section.hidden);
        if (firstVisible && (!state.activeGroupId || state.groups.find((group) => group.id === state.activeGroupId)?.section.hidden)) {
            setActiveGroup(firstVisible.id);
        }
        scheduleGroupOffsetRefresh();
    }

    function resetUiState() {
        state.fields.clear();
        state.groups = [];
        state.groupOffsets = [];
        state.activeGroupId = null;
        state.restarting = false;
        dom.sectionNav.replaceChildren();
        dom.fieldGroups.replaceChildren();
        dom.fieldSearch.value = '';
        dom.emptyState.hidden = true;
        dom.restartModal.hidden = true;
        dom.confirmRestart.disabled = false;
        dom.cancelRestart.disabled = false;
        dom.confirmRestart.textContent = 'Safely restart & restore';
    }

    function openEditor(payload, resourceName) {
        if (!payload || typeof payload !== 'object') return;
        resetUiState();

        state.open = true;
        state.sessionId = payload.sessionId != null ? String(payload.sessionId) : null;
        state.canEdit = payload.canEdit === true;
        state.nuiResource = resourceName || state.nuiResource;

        const vehicle = payload.vehicle && typeof payload.vehicle === 'object' ? payload.vehicle : {};
        const handling = payload.handling && typeof payload.handling === 'object' ? payload.handling : {};
        state.restartSupported = handling.restartSupported !== false;
        state.vehicleResource = safeText(handling.resource || handling.resourceName, 'unknown resource');

        const displayName = safeText(vehicle.displayName || vehicle.label || vehicle.modelName, 'Current vehicle');
        const modelName = safeText(vehicle.modelName || vehicle.model || vehicle.modelHash, 'unknown model');
        dom.breadcrumbVehicle.textContent = displayName;
        dom.vehicleName.textContent = displayName;
        dom.vehicleName.title = displayName;
        dom.vehicleModel.textContent = modelName;
        dom.handlingName.textContent = safeText(handling.name || handling.handlingName);
        dom.resourceName.textContent = state.vehicleResource;
        const path = safeText(handling.path || handling.filePath || handling.file);
        dom.sourcePath.textContent = path;
        dom.sourcePath.title = path;
        dom.restartResourceName.textContent = state.vehicleResource;

        dom.modeBadge.classList.toggle('mode-badge--edit', state.canEdit);
        dom.modeBadge.classList.toggle('mode-badge--view', !state.canEdit);
        dom.modeBadgeText.textContent = state.canEdit ? 'Edit access' : 'View-only access';
        dom.permissionCard.hidden = state.canEdit;
        dom.readonlyBanner.hidden = state.canEdit;
        dom.restartButton.hidden = !state.restartSupported;
        dom.restartButton.disabled = !state.canEdit || !state.restartSupported;
        dom.restartButton.title = state.canEdit ? 'Restart the owning vehicle resource' : 'Edit permission is required';

        const groups = Array.isArray(payload.groups) ? payload.groups : [];
        const navFragment = document.createDocumentFragment();
        const groupFragment = document.createDocumentFragment();
        groups.forEach((group, index) => {
            const model = createGroup(group || {}, index);
            if (model.models.length === 0) return;
            state.groups.push(model);
            navFragment.appendChild(model.nav);
            groupFragment.appendChild(model.section);
        });
        dom.sectionNav.appendChild(navFragment);
        dom.fieldGroups.appendChild(groupFragment);

        dom.fieldTotal.textContent = String(state.fields.size);
        if (state.groups.length > 0) setActiveGroup(state.groups[0].id);
        dom.emptyState.hidden = state.fields.size > 0;
        if (state.fields.size === 0) {
            dom.emptyState.querySelector('h3').textContent = 'No editable fields found';
            dom.emptyState.querySelector('p').textContent = 'This handling entry did not expose any supported values.';
        } else {
            dom.emptyState.querySelector('h3').textContent = 'No fields found';
            dom.emptyState.querySelector('p').textContent = 'Try another search term.';
        }

        dom.app.classList.remove('app--hidden');
        dom.app.setAttribute('aria-hidden', 'false');
        refreshGlobalStatus();
        scheduleGroupOffsetRefresh();
    }

    function hideEditor() {
        state.open = false;
        state.sessionId = null;
        dom.restartModal.hidden = true;
        dom.app.classList.add('app--hidden');
        dom.app.setAttribute('aria-hidden', 'true');

        // Release large handling-entry DOM trees after the close paint. A new
        // open message rebuilds them from its authoritative session payload.
        window.setTimeout(() => {
            if (state.open) return;
            state.fields.clear();
            state.groups = [];
            state.groupOffsets = [];
            state.activeGroupId = null;
            dom.sectionNav.replaceChildren();
            dom.fieldGroups.replaceChildren();
        }, 0);
    }

    function requestClose() {
        if (!state.open) return;
        hideEditor();
        void postNui('close').catch(() => {});
    }

    function openRestartConfirmation() {
        if (!state.open || !state.canEdit || state.restarting) return;
        dom.restartModal.hidden = false;
        window.setTimeout(() => dom.cancelRestart.focus(), 0);
    }

    function closeRestartConfirmation() {
        if (state.restarting) return;
        dom.restartModal.hidden = true;
        dom.restartButton.focus();
    }

    async function confirmRestart() {
        if (!state.open || !state.canEdit || state.restarting) return;
        state.restarting = true;
        dom.confirmRestart.disabled = true;
        dom.cancelRestart.disabled = true;
        dom.confirmRestart.textContent = 'Restarting…';

        try {
            const response = await postNui('restartResource');
            if (!response || response.ok !== true) throw new Error(response && response.error ? response.error : 'Restart rejected.');
            hideEditor();
        } catch (error) {
            state.restarting = false;
            dom.confirmRestart.disabled = false;
            dom.cancelRestart.disabled = false;
            dom.confirmRestart.textContent = 'Safely restart & restore';
            dom.restartModal.hidden = true;
            showToast(error.message || 'The resource could not be restarted.', 'error');
        }
    }

    let scrollFrame = null;
    let searchFrame = null;
    dom.fieldGroups.addEventListener('scroll', () => {
        if (scrollFrame !== null) return;
        scrollFrame = window.requestAnimationFrame(() => {
            scrollFrame = null;
            updateActiveGroupFromScroll();
        });
    }, { passive: true });

    dom.fieldSearch.addEventListener('input', () => {
        if (searchFrame) return;
        searchFrame = window.requestAnimationFrame(() => {
            searchFrame = null;
            applySearch();
        });
    });
    window.addEventListener('resize', scheduleGroupOffsetRefresh);
    dom.closeButton.addEventListener('click', requestClose);
    dom.restartButton.addEventListener('click', openRestartConfirmation);
    dom.cancelRestart.addEventListener('click', closeRestartConfirmation);
    dom.confirmRestart.addEventListener('click', () => void confirmRestart());

    window.addEventListener('keydown', (event) => {
        if (!state.open) return;
        if (event.key === 'Escape') {
            event.preventDefault();
            requestClose();
            return;
        }

        if (event.key === '/' && document.activeElement?.tagName !== 'INPUT') {
            event.preventDefault();
            dom.fieldSearch.focus();
        }
    });

    window.addEventListener('message', (event) => {
        const message = event.data;
        if (!message || typeof message !== 'object') return;

        switch (message.action) {
            case 'open':
                openEditor(message.data || message.payload, message.resourceName);
                break;
            case 'close':
                hideEditor();
                break;
            case 'saveResult':
                if (state.open) handleSaveResult(message);
                break;
            case 'toast':
            case 'notify':
                showToast(message.message, message.type || 'info');
                break;
            case 'restartOverlay':
                if (message.visible === true) {
                    dom.restartLoadingResource.textContent = safeText(message.resource, 'VEHICLE RESOURCE').toUpperCase();
                    dom.restartLoadingStage.textContent = safeText(message.stage, 'Preparing restart');
                    dom.restartLoadingDetail.textContent = safeText(message.detail, 'Capturing vehicles and their live properties.');
                    dom.restartLoading.hidden = false;
                } else {
                    dom.restartLoading.hidden = true;
                }
                break;
            default:
                break;
        }
    });
})();
