'use strict';

function formatArray(arr, options={
	itemPrepend: null,
	prependDelim: null,
}) {
	let out = [];
	for (const item of arr) {
		let fmtVal = formatEntry(item);
		if (options.itemPrepend && !options.prependDelim) {
			out.push(options.itemPrepend);
			out.push(fmtVal);
		} else {
			out.push(`${options.itemPrepend}${options.prependDelim}${fmtVal}`);
		}
	}

	return out;
}

function formatObject(obj, options={
	keyValueDelim: '=',
	paramDelim: ',',
}) {
	let out = [];
	for (const [key, value] of Object.entries(obj)) {
		let opts = {};
		let preamble = [];
		if (value instanceof Array) {
			opts.paramDelim = ',';
			opts.itemPrepend = key;
			opts.prependDelim = options.keyValueDelim;
		} else {
			preamble = [key, (value !== null) ? options.keyValueDelim : ''];
		}
		let fmtVal = formatEntry(value, opts);
		out.push(
			preamble.concat(
				(fmtVal instanceof Array) ? fmtVal : [fmtVal]
			).join('')
		);
	}

	return out;
}

function formatEntry(entry, options={
	paramDelim: ',',
	itemPrepend: null,
}) {
	let out = [];
	if (entry == null) {
		if (options.itemPrepend) out.push(options.itemPrepend);
	} else {
		switch (entry.constructor) {
			case Object:
				if (options.itemPrepend) out.push(options.itemPrepend);
				out = out.concat(formatObject(entry));
				break;
			case Array:
				out = out.concat(formatArray(entry, options));
				break
			case Boolean:
			case Number:
			case String:
				if (options.itemPrepend) out.push(options.itemPrepend);
				out = out.concat(entry);
				break;
		}
	}

	return options.paramDelim != null
		? out.join(options.paramDelim) : out;
}

module.exports = {
	formatCmdline: (template) => {
		let cmdline = [];
		for (const [key, value] of Object.entries(template)) {
			cmdline = cmdline.concat(
				formatEntry(value, {itemPrepend: `-${key}`})
			);
		}

		console.log(`cmdline: ${cmdline}`);
		return cmdline;
	}
};
