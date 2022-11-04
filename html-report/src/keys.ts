
const keys = {
    add: "\ue025",
    alt: "\ue00a",
    arrowDown: "\ue015",
    arrowLeft: "\ue012",
    arrowRight: "\ue014",
    arrowUp: "\ue013",
    backspace: "\ue003",
    cancel: "\ue001",
    clear: "\ue005",
    command: "\ue03d",
    control: "\ue009",
    decimal: "\ue028",
    "delete": "\ue017",
    divide: "\ue029",
    down: "\ue015",
    end: "\ue010",
    enter: "\ue007",
    equals: "\ue019",
    escape: "\ue00c",
    f1: "\ue031",
    f10: "\ue03a",
    f11: "\ue03b",
    f12: "\ue03c",
    f2: "\ue032",
    f3: "\ue033",
    f4: "\ue034",
    f5: "\ue035",
    f6: "\ue036",
    f7: "\ue037",
    f8: "\ue038",
    f9: "\ue039",
    help: "\ue002",
    home: "\ue011",
    insert: "\ue016",
    left: "\ue012",
    leftAlt: "\ue00a",
    leftControl: "\ue009",
    leftShift: "\ue008",
    meta: "\ue03d",
    multiply: "\ue024",
    "null": "\ue000",
    numpad0: "\ue01a",
    numpad1: "\ue01b",
    numpad2: "\ue01c",
    numpad3: "\ue01d",
    numpad4: "\ue01e",
    numpad5: "\ue01f",
    numpad6: "\ue020",
    numpad7: "\ue021",
    numpad8: "\ue022",
    numpad9: "\ue023",
    pageDown: "\ue00f",
    pageUp: "\ue00e",
    pause: "\ue00b",
    "return": "\ue006",
    right: "\ue014",
    semicolon: "\ue018",
    separator: "\ue026",
    shift: "\ue008",
    space: "\ue00d",
    subtract: "\ue027",
    tab: "\ue004",
    up: "\ue013"
};

const nameByKey = Object.fromEntries(Object.entries(keys).map(([name, key]) => [key, name]));

export function keyName(key: string): string | null {
    const name = nameByKey[key];
    return name === undefined ? null : `keys.${name}`;
};
