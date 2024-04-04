from vllm.timings.timer import Timer

__all__ = ["log_time", "get_singleton_manager"]


def get_singleton_manager(enable_logging: bool = False):
    """
    Return the Timer. If not has not yet been initialized, initialize and
    return. If it has, return the existing Timer.
    """
    if Timer._instance is None:
        Timer._instance = Timer(enable_logging=enable_logging)
    return Timer._instance


def log_async_time(func):
    """
    Decorator to time async functions. Times for the function are stored using
    the class and function names.
    """

    async def wrapper(self, *arg, **kwargs):
        TIMER_MANAGER = get_singleton_manager()
        func_name = f"{self.__class__.__name__}.{func.__name__}"
        if not TIMER_MANAGER.enable_logging:
            return await func(self, *arg, **kwargs)

        with TIMER_MANAGER.time(func_name):
            return await func(self, *arg, **kwargs)

    return wrapper


def log_time(func):
    """
    Decorator to time functions. Times for the function are stored using
    the class and function names.
    """

    def wrapper(self, *arg, **kwargs):
        TIMER_MANAGER = get_singleton_manager()
        func_name = f"{self.__class__.__name__}.{func.__name__}"
        if not TIMER_MANAGER.enable_logging:
            return func(self, *arg, **kwargs)

        with TIMER_MANAGER.time(func_name):
            return func(self, *arg, **kwargs)

    return wrapper
