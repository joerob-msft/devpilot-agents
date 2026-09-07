// ConPTY emits cell updates, not complete lines. Removing ANSI codes alone
// concatenates old/new text and can report corruption that isn't on screen.
// This test helper covers the dashboard fixtures' single-cell glyphs and CSI output.
export class TerminalScreen {
  private rows: string[][] = [];
  private row = 0;
  private column = 0;
  private pending = "";
  private columns = 130;
  private height = 36;
  private autoWrap = true;
  private wrapPending = false;

  resize(columns: number, rows: number): void {
    this.columns = columns;
    this.height = rows;
    this.rows.length = Math.min(this.rows.length, rows);
    for (const row of this.rows) if (row) row.length = Math.min(row.length, columns);
    this.row = Math.min(this.row, rows - 1);
    this.column = Math.min(this.column, columns - 1);
    this.wrapPending = false;
  }

  write(chunk: string): void {
    this.pending += chunk;
    while (this.pending.length) {
      if (this.pending[0] === "\x1b") {
        if (this.pending.length < 2) return;
        if (this.pending[1] === "[") {
          const match = /^\x1b\[([0-?]*)([ -/]*)([@-~])/.exec(this.pending);
          if (!match) return;
          this.pending = this.pending.slice(match[0].length);
          this.csi(match[1]!, match[3]!);
          continue;
        }
        if (this.pending[1] === "]" || this.pending[1] === "P") {
          const end = /\x07|\x1b\\/.exec(this.pending.slice(2));
          if (!end) return;
          this.pending = this.pending.slice(2 + end.index + end[0].length);
          continue;
        }
        this.pending = this.pending.slice(2);
        continue;
      }
      const character = String.fromCodePoint(this.pending.codePointAt(0)!);
      this.pending = this.pending.slice(character.length);
      if (character === "\r") { this.column = 0; this.wrapPending = false; }
      else if (character === "\n") { this.lineFeed(); this.wrapPending = false; }
      else if (character === "\b") { this.column = Math.max(0, this.column - 1); this.wrapPending = false; }
      else if (character === "\t") {
        this.column = Math.min(this.columns - 1, (Math.floor(this.column / 8) + 1) * 8);
        this.wrapPending = false;
      } else if (character >= " ") {
        if (this.wrapPending) {
          this.column = 0;
          this.lineFeed();
          this.wrapPending = false;
        }
        const row = this.rows[this.row] ??= [];
        row[this.column] = character;
        if (this.column === this.columns - 1) this.wrapPending = this.autoWrap;
        else this.column++;
      }
    }
  }

  private lineFeed(): void {
    if (this.row === this.height - 1) {
      this.rows.shift();
      this.rows[this.row] = [];
    } else this.row++;
  }

  private csi(parameters: string, command: string): void {
    if (parameters.startsWith("?")) {
      if (parameters === "?7") { this.autoWrap = command === "h"; this.wrapPending = false; }
      if (parameters === "?1049" && command === "h") {
        this.rows = [];
        this.row = this.column = 0;
        this.wrapPending = false;
      }
      return;
    }
    const values = parameters.split(";").map((value) => Number(value) || 0);
    const first = values[0] ?? 0;
    const amount = first || 1;
    if ("HfABCDGdJKX".includes(command)) this.wrapPending = false;
    if (command === "H" || command === "f") {
      this.row = Math.min(this.height - 1, Math.max(0, amount - 1));
      this.column = Math.min(this.columns - 1, Math.max(0, (values[1] || 1) - 1));
    } else if (command === "A") this.row = Math.max(0, this.row - amount);
    else if (command === "B") this.row = Math.min(this.height - 1, this.row + amount);
    else if (command === "C") this.column = Math.min(this.columns - 1, this.column + amount);
    else if (command === "D") this.column = Math.max(0, this.column - amount);
    else if (command === "G") this.column = Math.min(this.columns - 1, amount - 1);
    else if (command === "d") this.row = Math.min(this.height - 1, amount - 1);
    else if (command === "J") {
      if (first === 2 || first === 3) this.rows = [];
      else if (first === 0) {
        this.rows.splice(this.row + 1);
        this.rows[this.row]?.splice(this.column);
      }
    } else if (command === "K" || command === "X") {
      const row = this.rows[this.row] ??= [];
      if (command === "X") {
        for (let index = this.column; index < Math.min(this.columns, this.column + amount); index++) row[index] = " ";
      } else if (first === 2) this.rows[this.row] = [];
      else if (first === 0) row.splice(this.column);
      else for (let index = 0; index <= this.column; index++) row[index] = " ";
    }
  }

  text(): string {
    return Array.from({ length: this.rows.length }, (_, index) => {
      const row = this.rows[index]?.slice(0, this.columns) ?? [];
      return Array.from({ length: row.length }, (_, column) => row[column] ?? " ").join("").trimEnd();
    }).join("\n");
  }
}
