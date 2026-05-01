EMU_PER_INCH = 914400
TWIPS_PER_INCH = 1440


class Length(int):
    @property
    def emu(self) -> int:
        return int(self)

    @property
    def twips(self) -> int:
        return int(round(int(self) / EMU_PER_INCH * TWIPS_PER_INCH))


def Inches(value: float) -> Length:
    return Length(round(float(value) * EMU_PER_INCH))


def Pt(value: float) -> Length:
    return Length(round(float(value) * 12700))


def Twips(value: int) -> Length:
    return Length(round(int(value) / TWIPS_PER_INCH * EMU_PER_INCH))


class RGBColor(str):
    @classmethod
    def from_string(cls, value: str) -> "RGBColor":
        return cls(value)
