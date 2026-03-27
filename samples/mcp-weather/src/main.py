import random
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("weather-server", host="0.0.0.0", port=8000)


@mcp.tool()
def get_weather(location: str) -> str:
    """Get the current weather for a location.

    Args:
        location: City or location name (e.g. "New York", "London")

    Returns:
        Weather description with condition and temperature.
    """
    conditions = ["Sunny", "Cloudy", "Rainy", "Snowy", "Partly Cloudy", "Windy", "Foggy"]
    condition = random.choice(conditions)
    temp_c = random.randint(-10, 40)
    temp_f = round(temp_c * 9 / 5 + 32)
    humidity = random.randint(20, 95)

    return (
        f"Weather in {location}: {condition}, "
        f"{temp_c}°C ({temp_f}°F), "
        f"Humidity: {humidity}%"
    )


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
