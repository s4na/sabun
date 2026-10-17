const fs = require('node:fs');
class SabunReporter {
  constructor() {
    this.expected = [];
    this.completed = new Set();
    this.failed = true;
  }
  onBegin(_config, suite) {
    this.expected = suite.allTests().filter(test => test.expectedStatus !== 'skipped').map(test => test.id);
    this.completed = new Set();
    this.failed = false;
  }
  onTestEnd(test, result) {
    if (result.status === 'passed') this.completed.add(test.id);
    else if (result.status !== 'skipped') this.failed = true;
  }
  onError() {
    this.failed = true;
  }
  onEnd(result) {
    const output = process.env.SABUN_RECORD_FILE;
    if (!output) return;
    fs.writeFileSync(`${output}.manifest.json`, JSON.stringify({
      complete: result.status === 'passed' && !this.failed && this.expected.length > 0 && this.expected.every(id => this.completed.has(id)),
      tests: this.expected,
    }));
  }
}
module.exports = SabunReporter;
