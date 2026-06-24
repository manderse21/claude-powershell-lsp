class Shape {
    [string]$Kind

    Shape([string]$kind) {
        $this.Kind = $kind
    }

    [string] Render() {
        return $this.Kind
    }
}

class Circle : Shape {
    [double]$Radius

    Circle([double]$radius) : base('circle') {
        $this.Radius = $radius
    }

    [string] Render() {
        return ('circle r=' + $this.Radius)
    }
}
