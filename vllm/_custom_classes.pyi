class VLLMType:

    def __init__(self, mantissa: int, exponent: int, signed: bool) -> None:
        ...

    @property
    def mantissa(self) -> int:
        ...

    @property
    def exponent(self) -> int:
        ...

    @property
    def signed(self) -> bool:
        ...

    @property
    def size_bits(self) -> int:
        ...

    @property
    def integer(self) -> bool:
        ...

    @property
    def floating_point(self) -> bool:
        ...

    def __eq__(self, value: object) -> bool:
        ...

    def __str__(self) -> str:
        ...
