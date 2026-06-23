class Widget {
    [string]$Name
    [int]$Size

    Widget([string]$name, [int]$size) {
        $this.Name = $name
        $this.Size = $size
    }

    [string] Describe() {
        return ($this.Name + ' (' + $this.Size + ')')
    }
}
