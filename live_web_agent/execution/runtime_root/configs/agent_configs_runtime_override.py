"""Frozen AgentLab configuration used by the submitted live evaluation."""

from bgym import HighLevelActionSetArgs
from agentlab.agents import dynamic_prompting as dp
from agentlab.llm.llm_configs import CHAT_MODEL_ARGS_DICT

from .generic_agent import GenericAgentArgs
from .tmlr_config import BASE_FLAGS

# The submitted live evaluation uses this configuration only.
GPT5_MINI_FLAGS = BASE_FLAGS.copy()
GPT5_MINI_FLAGS.action = dp.ActionFlags(
    action_set=HighLevelActionSetArgs(
        subsets=["bid"],
        multiaction=False,
    )
)

AGENT_GPT5_MINI = GenericAgentArgs(
    chat_model_args=CHAT_MODEL_ARGS_DICT["openai/gpt-5-mini-2025-08-07"],
    flags=GPT5_MINI_FLAGS,
)
